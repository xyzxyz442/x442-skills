import { NestFactory } from '@nestjs/core';
import { MicroserviceOptions, Transport } from '@nestjs/microservices';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.createMicroservice<MicroserviceOptions>(
    AppModule,
    {
      transport: Transport.KAFKA,
      options: {
        client: { brokers: (process.env.KAFKA_BROKERS ?? '').split(',') },
        consumer: { groupId: 'orders-ingest-v2' },
      },
    },
  );
  await app.listen();
}
bootstrap();
