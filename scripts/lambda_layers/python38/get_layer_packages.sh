
#!/bin/bash

export PKG_DIR="python"

rm -rf ${PKG_DIR} && mkdir -p ${PKG_DIR}
docker build -t lamda-golden:latest .
docker run --rm -v $(pwd):/foo -w /foo lamda-golden:latest \
    pip install -r requirements.txt --no-deps -t ${PKG_DIR}
