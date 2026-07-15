import requests

def lambda_handler(event,context):
    response = requests.get("http://checkip.amazonaws.com")
    assert response.status_code == 200
