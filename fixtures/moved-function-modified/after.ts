const VAT_RATE = 0.25;

export function formatPrice(value: number): string {
  const rounded = value.toFixed(2);
  return `${rounded} zl`;
}
