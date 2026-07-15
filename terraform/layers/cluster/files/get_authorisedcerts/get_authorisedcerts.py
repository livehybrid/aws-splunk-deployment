#! /usr/bin/python
import boto3
from boto3.dynamodb.conditions import Key, Attr

def handler(event, context):
    dynamodb = boto3.resource('dynamodb')
    table = dynamodb.Table("certificates")

    response = table.query(
        IndexName='idx-enabled',
        KeyConditionExpression=Key('enabled').eq(1)
    )

    certificates = response['Items']
    cert_serials = [item['serial'] for item in certificates]
    return ('\n'.join(cert_serials))