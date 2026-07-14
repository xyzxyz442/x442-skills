export function toUpperKey(
  input: Record<string, unknown>,
): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(input).map(([key, value]) => [key.toUpperCase(), value]),
  );
}
