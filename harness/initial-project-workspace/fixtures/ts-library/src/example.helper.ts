export function greet(name: string): string {
  return `Hello, ${name}!`;
}

export function slugify(input: string): string {
  return input
    .trim()
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean)
    .join('-');
}
