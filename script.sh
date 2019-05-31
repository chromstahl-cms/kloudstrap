#!/bin/bash

if ! [ -x "$(command -v jq)" ]; then
    echo 'Error: "jq" is not installed.' >&2
    echo 'Please install it and try again.' >&2
    exit 1
fi

rm -f .fdn

PLUGIN_DIR="extracted_plugins"
if [ ! -d $PLUGIN_DIR ]; then
    mkdir $PLUGIN_DIR
fi

CHANGED=false

for filename in plugins/*.tar.gz; do
    META=$(tar xfO $filename meta.json)
    AUTHOR=$(echo $META | jq -r '.author')
    NAME=$(echo $META | jq -r '.name')
    VERSION=$(echo $META | jq -r '.version')
    FULLY_QUALIFIED=$PLUGIN_DIR/$AUTHOR/$NAME/$VERSION
    echo $FULLY_QUALIFIED >> .fdn
    if [ ! -d $FULLY_QUALIFIED ]; then
        CHANGED=true
        echo "Found new Plugin $NAME from $AUTHOR in version $VERSION"
        mkdir -p $FULLY_QUALIFIED
        tar xvf $filename -C $FULLY_QUALIFIED &>/dev/null
    fi
done

function writeDockerFile {
    echo "ADD $1 $1" >> Dockerfile
}

function addToDockerFile {
    echo "ADD $1 $2" >> Dockerfile
}

function runInDocker {
    echo "RUN $1" >> Dockerfile
}

function nginxConf {
    cat << EOF >> nginx.conf
events {
    worker_connections  4096;  ## Default: 1024
}

http {
    server {
        listen 80;
        listen [::]:80;

        server_name api.localhost;

        location / {
            proxy_pass http://127.0.0.1:8083;
        }
    }

    server {
        listen 80 default_server;
        listen [::]:80 default_server;

        root /usr/share/nginx/html/;

        index index.html;

        server_name _;

        location ~* \.(?:ico|gif|jpe?g|png|svg)$ {
            include /etc/nginx/mime.types;
            expires max;
            add_header Pragma public;
            add_header Cache-Control "public, must-revalidate, proxy-revalidate";
        }

        location / {
            proxy_set_header Host \$http_host\$uri;
            try_files \$uri \$uri/ /index.html =404;
        }

    }
}
EOF
}

function dockerCompose {
    DATA_BASE_DIR="$HOME/.chromstahl"
    mkdir -p $DATA_BASE_DIR
    cat << EOF >> docker-compose.yml
version: "3"

services:
  core:
    build: $PWD
    image: core
    environment:
      SPRING_APPLICATION_JSON: '{"spring.datasource": {"url": "jdbc:mysql://db:3306/kms?useSSL=false", "password": "kloudfile"}}'
    ports:
      - 8083:8083
      - 4444:80
    volumes:
EOF
    DATA_DIR="$DATA_BASE_DIR/data"
    echo "      - $DATA_DIR:/root/.chromstahl/data" >> docker-compose.yml
    cat << EOF >> docker-compose.yml
  db:
    environment:
      MYSQL_ROOT_PASSWORD: kloudfile
      MYSQL_DATABASE: kms
    image: mysql:5.7
    ports:
      - 3306:3306
    volumes:
EOF
    DB_DIR="$DATA_BASE_DIR/db"
    echo "      - $DB_DIR/lib:/var/lib/mysql" >> docker-compose.yml
    echo "      - $DB_DIR/cnf:/var/cnf/mysql" >> docker-compose.yml
    echo "      - $DB_DIR/log:/var/log/mysql" >> docker-compose.yml
}

function prepDocker {
    rm -f Dockerfile
    cat << EOF >> Dockerfile
FROM voidlinux/voidlinux
# Install java
RUN xbps-install -Syu wget nodejs git nginx
RUN xbps-install -y gradle && mkdir gradle && cd gradle && gradle wrapper --gradle-distribution-url https\://services.gradle.org/distributions/gradle-5.2.1-all.zip && ./gradlew build && xbps-remove -Ry gradle && cd ../ && rm -rf gradle/
RUN npm i -g parcel
RUN wget https://download.java.net/java/GA/jdk12/GPL/openjdk-12_linux-x64_bin.tar.gz -O /tmp/jdk.tar.gz && \
 mkdir -p /opt/jvm && \
 tar xfvz /tmp/jdk.tar.gz --directory /opt/jvm && \
 rm -f /tmp/openjdk-11+28_linux-x64_bin.tar.gz
ENV PATH="\$PATH:/opt/jvm/jdk-12/bin"
ADD package.json /tmp/package.json

RUN cd /tmp && sed -e '/cypress/d' -i package.json && npm install

ARG FRONTEND_SHA
RUN echo $FRONTEND_SHA
RUN git clone https://github.com/chromstahl-cms/frontend.git
RUN cd frontend && cp -r /tmp/node_modules .
ARG BACKEND_SHA
RUN echo $BACKEND_SHA
RUN git clone https://github.com/chromstahl-cms/chromstahl-core.git && cd chromstahl-core && ./gradlew build -x test
EOF
}

if $CHANGED; then
    GRADLE=$(curl https://raw.githubusercontent.com/kloud-ms/kms-core/master/build.gradle 2>/dev/null | sed \$d)
    curl https://raw.githubusercontent.com/kloud-ms/frontend/master/src/index.ts 2>/dev/null 1> index.ts
    curl https://raw.githubusercontent.com/chromstahl-cms/frontend/master/package.json 2>/dev/null 1> package.json
    prepDocker
    while read path; do
        writeDockerFile $path
        GRADLE="$GRADLE
        compile files('/$path/plugin.jar')"
        runInDocker "cd frontend && sed -e '/cypress/d' -i package.json &&  npm install /$path/frontend.tgz"
        PACKAGE_NAME=$(tar -xOzf $path/frontend.tgz package/package.json | jq -r '.name')
        NEW_UUID=$(cat /dev/urandom | tr -dc 'a-zA-Z' | fold -w 32 | head -n 1)
        sed -i -e '/$$MARK/a\' -e "import $NEW_UUID from '$PACKAGE_NAME'; pluginMaps.push(new $NEW_UUID().register());" index.ts
    done <.fdn
    GRADLE="$GRADLE
}"
    echo "$GRADLE" > build.gradle
    addToDockerFile nginx.conf /etc/nginx/nginx.conf
    addToDockerFile build.gradle chromstahl-core/build.gradle
    addToDockerFile index.ts frontend/src/index.ts
    runInDocker "cd frontend && npm i && parcel build src/index.html && rm -rf /usr/share/nginx/html/* && cp dist/* /usr/share/nginx/html"
    nginxConf
    dockerCompose
    echo "ENTRYPOINT sh -c 'nginx && cd chromstahl-core && ./gradlew bootRun'" >> Dockerfile
fi
