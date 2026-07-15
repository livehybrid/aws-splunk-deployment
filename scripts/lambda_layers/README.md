Run build.sh to create the layer.zip (in ./layer)  
Run test.sh to test the the layer works, this runs a simple script in ./test - expand this test if you add additional modules in requirements.txt  
Run publish.sh to upload the layer to AWS - this will return the ARN for the new layer in a JSON output. Update the lambda_layer_openssl/lambda_layer_python_requests variable in the terraform/layers/_shared/vars/<env>.tf file
Remember to publish the layer in each environment!  

