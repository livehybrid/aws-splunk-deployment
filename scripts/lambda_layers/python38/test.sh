#!/bin/sh

rm -rf layer/files && unzip layer/layer.zip -d layer/files

docker run --rm -v "$PWD"/test/:/var/task -v "$PWD"/layer/files/opt:/opt lambci/lambda:python3.8 index.lambda_handler

