import json
import urllib3

def lambda_handler(event, context):
    #Parse URL Parameters
    http_method = event["queryStringParameters"]["http_method"]
    url = event["queryStringParameters"]["url"]
    port = event["queryStringParameters"]["port"]
    token = event["queryStringParameters"]["token"]


    #Build Full URL out of Parameters
    full_url = http_method+'://'+url+':'+port+'/services/collector/raw'


    #Create URLLib3 Pool Manager
    http = urllib3.PoolManager()
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    #Post Event
    r = http.request('POST', full_url, body=event["body"].encode('utf-8'), headers={'Content-Type': 'application/json', 'Authorization':'Splunk '+token})

    return {
        'statusCode': 200,
        'body':'Success'
    }