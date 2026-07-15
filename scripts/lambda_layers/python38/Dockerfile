FROM lambci/lambda:build-python3.8
RUN yum install zip -y
COPY requirements.txt requirements.txt
RUN pip install -r requirements.txt -t /python
