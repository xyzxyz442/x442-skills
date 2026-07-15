export interface InvoiceItem {
  description: string;
  amount: number;
}

export function calculateInvoiceTotal(items: InvoiceItem[]): number {
  return items.reduce((sum, item) => sum + item.amount, 0);
}
