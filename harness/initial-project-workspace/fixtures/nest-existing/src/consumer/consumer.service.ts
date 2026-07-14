import { Injectable } from '@nestjs/common';
import { toUpperKey } from '../utils/helper';

@Injectable()
export class ConsumerService {
  handle(message: Record<string, unknown>): Record<string, unknown> {
    return toUpperKey(message);
  }
}
