function alpha(input: string) {
  return input.trim().toLowerCase();
}

async function fetchUser(id: string) {
  const response = await fetch(`/api/users/${id}`);
  return response.json();
}

class Repository {
  private items = new Map<string, unknown>();
}

function beta(values: number[]) {
  return values.reduce((sum, value) => sum + value, 0);
}
