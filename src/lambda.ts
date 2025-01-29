import "./config";
import { SQSEvent, SQSHandler, APIGatewayEvent, APIGatewayProxyHandler, APIGatewayProxyResult } from "aws-lambda";
import { Client } from "@opensearch-project/opensearch";
import { AwsSigv4Signer } from "@opensearch-project/opensearch/lib/aws";
import { ResponseError } from "@opensearch-project/opensearch/lib/errors";
import { join } from "path";

interface Model {
  index: string;
  id: number;
  data: any; 
}

export const handler: SQSHandler = async (event: SQSEvent) => {
  for (const record of event.Records) {
    try {
      const { body, receiptHandle } = record;
      const message = JSON.parse(body);

      const openSearchClient = new Client({
        ...AwsSigv4Signer({
          region: "sa-east-1",
          getCredentials: async () => ({
            accessKeyId: process.env.AWS_ACCESS_KEY_ID!,
            secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY!,
          }),
        }),
        node: process.env.OPENSEARCH_NODE!,
      });


      const model: Model = {
        index: message.topic,
        id: message.id,
        data: message,
      };

      await openSearchClient.index({
        index: model.index,
        id: model.id?.toString(),
        body: model.data,
      });

      console.log("Dados indexados no OpenSearch:", model);
    } catch (error) {
      if (error instanceof ResponseError) {
        console.error("ResponseError details:", error.meta.body);
        return;
      }

      console.error("Error processing record:", record);
      console.error("Error details:", error);
    }
  }
};

export const apiGatewayHandler: APIGatewayProxyHandler = async (event: APIGatewayEvent): Promise<APIGatewayProxyResult> => {
  let params = event.queryStringParameters || {}

  let currentPage =  Number(params.page) || 1; 
  let pageSize = Number(params.limitPerPage) || 1;
  const from = (currentPage - 1) * pageSize;
  
  const openSearchClient = new Client({
    ...AwsSigv4Signer({
      region: "sa-east-1",
      getCredentials: async () => ({
        accessKeyId: process.env.AWS_ACCESS_KEY_ID!,
        secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY!,
      }),
    }),
    node: process.env.OPENSEARCH_NODE!,
  });

  let searchAttributes = {
    index: params.topic,
    body: {
      query: {
        match_all: {}
      },
      sort: [
        {
          ['id']: 'asc'
        }
      ],
      from : from,
      size: pageSize
    }
  };

  const response = await openSearchClient.search(searchAttributes);

  // const response = await openSearchClient.deleteByQuery({
  //   index: 'payment',
  //   body: {
  //     query: {  
  //       match_all: {} 
  //     }
  //   }
  // });

  return {
    statusCode: 200,
    body: JSON.stringify(response.body.hits)
  };
} 

