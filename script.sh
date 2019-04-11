#!/bin/bash

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

function prepDocker {
    rm -f Dockerfile
    cat << EOF >> Dockerfile
FROM voidlinux/voidlinux
# Install java
RUN xbps-install -Syu wget nodejs git
RUN wget https://download.java.net/java/GA/jdk12/GPL/openjdk-12_linux-x64_bin.tar.gz -O /tmp/jdk.tar.gz && \
 mkdir -p /opt/jvm && \
 tar xfvz /tmp/jdk.tar.gz --directory /opt/jvm && \
 rm -f /tmp/openjdk-11+28_linux-x64_bin.tar.gz
ENV PATH="\$PATH:/opt/jvm/jdk-12/bin"

RUN git clone https://github.com/kloud-ms/frontend.git
RUN git clone https://github.com/kloud-ms/kms-core.git
EOF
}

if $CHANGED; then
    GRADLE=$(curl https://raw.githubusercontent.com/kloud-ms/kms-core/master/build.gradle 2>/dev/null | sed \$d)
    #PACKAGE_JSON=$(curl https://raw.githubusercontent.com/kloud-ms/frontend/master/package.json 2>/dev/null)
    prepDocker
    while read path; do
        writeDockerFile $path
        GRADLE="$GRADLE
        compile files('$path/plugin.jar')"
        #PACKAGE_JSON=$(echo "$PACKAGE_JSON"  | sed -e '/"dependencies":/a\' -e "        \"$path\": \"$path/frontend.tgz\",")
        runInDocker "cd frontend &&  npm install /$path/frontend.tgz"
    done <.fdn
    GRADLE="$GRADLE
}"
    #echo "$PACKAGE_JSON" > package.json
    echo "$GRADLE" > build.gradle
    addToDockerFile build.gradle kms-core/build.gradle
    #addToDockerFile package.json frontend/package.json
fi
