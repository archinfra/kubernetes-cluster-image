#!/bin/bash

mkdir -p /root/.kube

cat > .kube/config <<EOF
apiVersion: v1
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: $APISERVER
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: $USER_NAME
    namespace: $NAMESPACE
  name: $USER_NAME
current-context: $USER_NAME
kind: Config
preferences: {}
users:
- name: $USER_NAME
  user:
    token: $USER_TOKEN
EOF

ENV CREDENTIAL_OPTION ""
ENV AUTH_HEADER_OPTION ""

if [ -n "$CREDENTIAL" ]
then
    CREDENTIAL_OPTION="-c $CREDENTIAL"
fi

if [ -n "$AUTH_HEADER" ]
then
    AUTH_HEADER_OPTION="-H $AUTH_HEADER"
fi

ttyd -p 8080 --writable $AUTH_HEADER_OPTION $CREDENTIAL_OPTION bash
