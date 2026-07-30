export function formatPrice(value: number): string {
  const rounded = value.toFixed(2);
  return `${rounded} zl`;
}

const VAT_RATE = 0.23;
