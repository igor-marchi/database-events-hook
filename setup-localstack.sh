# #!/bin/bash

# Carregar variáveis de ambiente do arquivo .env
echo "Carregando variáveis de ambiente do arquivo .env..."
. "$(dirname "$0")/.env"
if [ $? -ne 0 ]; then
  echo "Falha ao carregar variáveis de ambiente"
  exit 1
fi
echo "Variáveis de ambiente carregadas com sucesso"

# Remove the /dist directory and /src/lambda.zip file if they exist
echo "Removendo diretório /dist e arquivo /src/lambda.zip se existirem..."
rm -rf dist
rm -f src/lambda.zip
echo "Diretório /dist e arquivo /src/lambda.zip removidos"

# Create SQS queue
echo "Criando fila SQS payments.fifo..."
PAYMENT_QUEUE_URL=$(awslocal sqs create-queue --queue-name payments.fifo --attributes FifoQueue=true --query 'QueueUrl' --output text) > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Falha ao criar fila SQS payments.fifo"
  exit 1
fi
echo "Created SQS queue with URL: $PAYMENT_QUEUE_URL"

# Create SQS queue
echo "Criando fila SQS customers.fifo..."
CUSTOMER_QUEUE_URL=$(awslocal sqs create-queue --queue-name customers.fifo --attributes FifoQueue=true --query 'QueueUrl' --output text) > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Falha ao criar fila SQS customers.fifo"
  exit 1
fi
echo "Created SQS queue with URL: $CUSTOMER_QUEUE_URL"

# Get SQS queue ARN
echo "Obtendo ARN da fila SQS payments.fifo..."
PAYMENT_QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url $PAYMENT_QUEUE_URL --attribute-names QueueArn --query 'Attributes.QueueArn' --output text) > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Falha ao obter ARN da fila SQS payments.fifo"
  exit 1
fi
echo "SQS queue ARN: $PAYMENT_QUEUE_ARN"

# Get SQS queue ARN
echo "Obtendo ARN da fila SQS customers.fifo..."
CUSTOMER_QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url $CUSTOMER_QUEUE_URL --attribute-names QueueArn --query 'Attributes.QueueArn' --output text) > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Falha ao obter ARN da fila SQS customers.fifo"
  exit 1
fi
echo "SQS queue ARN: $CUSTOMER_QUEUE_ARN"

# Build the Lambda function
echo "Building the Lambda function..."
npm run build > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Failed to build the Lambda function"
  exit 1
fi
echo "Lambda function built successfully"

# Create Lambda zip file without including the directory structure
echo "Creating Lambda zip file..."
zip -j src/lambda.zip dist/lambda.js > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Failed to create Lambda zip file"
  exit 1
fi
echo "Lambda zip file created successfully"

# Create Lambda function sqsConsumer
echo "Creating Lambda function sqsConsumer..."
awslocal lambda create-function --function-name sqsConsumer \
  --runtime nodejs14.x \
  --handler lambda.handler \
  --zip-file fileb://src/lambda.zip \
  --role arn:aws:iam::000000000000:role/lambda-role \
  --environment Variables="{SQS_QUEUE_URL=$PAYMENT_QUEUE_URL, DATABASE_URL=$DATABASE_URL, OPENSEARCH_NODE=$OPENSEARCH_NODE, AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY}" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Failed to create Lambda function sqsConsumer"
  exit 1
fi
echo "Lambda function sqsConsumer created successfully"

# Wait for the Lambda function to become active
echo "Waiting for Lambda function sqsConsumer to become active..."
while true; do
  STATE=$(awslocal lambda get-function --function-name sqsConsumer --query 'Configuration.State' --output text) > /dev/null 2>&1
  if [ "$STATE" = "Active" ]; then
    echo "Lambda function sqsConsumer is active"
    break
  elif [ "$STATE" = "Failed" ]; then
    echo "Lambda function sqsConsumer creation failed"
    exit 1
  else
    echo "Lambda function sqsConsumer is in state $STATE. Waiting..."
    sleep 5
  fi
done

# Create event source mapping sqsConsumer for PAYMENT_QUEUE_ARN
echo "Creating event source mapping for PAYMENT_QUEUE_ARN..."
awslocal lambda create-event-source-mapping \
  --function-name sqsConsumer \
  --batch-size 10 \
  --event-source-arn $PAYMENT_QUEUE_ARN > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Failed to create event source mapping for PAYMENT_QUEUE_ARN"
  exit 1
fi
echo "Event source mapping for PAYMENT_QUEUE_ARN created successfully"

# Create event source mapping sqsConsumer for CUSTOMER_QUEUE_ARN
echo "Creating event source mapping for CUSTOMER_QUEUE_ARN..."
awslocal lambda create-event-source-mapping \
  --function-name sqsConsumer \
  --batch-size 10 \
  --event-source-arn $CUSTOMER_QUEUE_ARN > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Failed to create event source mapping for CUSTOMER_QUEUE_ARN"
  exit 1
fi
echo "Event source mapping for CUSTOMER_QUEUE_ARN created successfully"

# List event source mappings for sqsConsumer
echo "Listing event source mappings for sqsConsumer..."
awslocal lambda list-event-source-mappings --function-name sqsConsumer > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Failed to list event source mappings for sqsConsumer"
  exit 1
fi
echo "Event source mappings for sqsConsumer listed successfully"

# Create Lambda function apiGatewayHandler
echo "Creating Lambda function apiGatewayHandler..."
awslocal lambda create-function --function-name apiGatewayHandler \
  --runtime nodejs14.x \
  --handler lambda.apiGatewayHandler \
  --zip-file fileb://src/lambda.zip \
  --role arn:aws:iam::000000000000:role/lambda-role \
  --environment Variables="{OPENSEARCH_NODE=$OPENSEARCH_NODE, AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY}" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Failed to create Lambda function apiGatewayHandler"
  exit 1
fi
echo "Lambda function apiGatewayHandler created successfully"

# Criar API Gateway

# Variáveis
API_NAME="openSeachApiGateway"
STAGE_NAME="dev"

echo "Criando API Gateway: $API_NAME"
API_ID=$(awslocal apigateway create-rest-api --name "$API_NAME" --query 'id' --output text) > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Falha ao criar API Gateway: $API_NAME"
  exit 1
fi
echo "API criada com ID: $API_ID"

# Obter o ID do recurso raiz
echo "Obtendo o ID do recurso raiz..."
ROOT_RESOURCE_ID=$(awslocal apigateway get-resources --rest-api-id "$API_ID" --query 'items[0].id' --output text) > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Falha ao obter o ID do recurso raiz"
  exit 1
fi
echo "ID do recurso raiz: $ROOT_RESOURCE_ID"

# Criar recurso '/search'
echo "Criando recurso '/search'"
RESOURCE_ID=$(awslocal apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT_RESOURCE_ID" --path-part search --query 'id' --output text) > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Falha ao criar recurso '/search'"
  exit 1
fi
echo "Recurso '/search' criado com ID: $RESOURCE_ID"

# Adicionar método GET ao recurso '/search'
echo "Adicionando método GET ao recurso '/search'"
awslocal apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method GET --authorization-type "NONE" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Falha ao adicionar método GET ao recurso '/search'"
  exit 1
fi
echo "Método GET adicionado ao recurso '/search'"

# Configurar integração MOCK para o método GET
echo "Configurando integração MOCK para o método GET"
awslocal apigateway put-integration \
 --rest-api-id $API_ID \
 --resource-id $RESOURCE_ID \
 --http-method GET \
 --type AWS_PROXY \
 --integration-http-method POST \
 --uri arn:aws:apigateway:localstack:lambda:path/2015-03-31/functions/arn:aws:lambda:sa-east-1:000000000000:function:apiGatewayHandler/invocations > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Falha ao configurar integração MOCK para o método GET"
  exit 1
fi
echo "Integração MOCK configurada para o método GET"

# Implantar a API
echo "Implantando a API no stage '$STAGE_NAME'"
awslocal apigateway create-deployment --rest-api-id "$API_ID" --stage-name "$STAGE_NAME" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Falha ao implantar a API no stage '$STAGE_NAME'"
  exit 1
fi
echo "API implantada no stage '$STAGE_NAME'"

# Exibir endpoint de teste
ENDPOINT="http://localhost:4566/restapis/$API_ID/$STAGE_NAME/_user_request_"
echo "API Gateway configurada com sucesso!"
echo "Teste o endpoint usando: curl $ENDPOINT"