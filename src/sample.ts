// Sample file to demonstrate Claude Review Lens extension
// This file has intentional code patterns that trigger review comments

export function processUserData(data: unknown): string {
  // This could use better type narrowing
  const userData = data as { name: string; email: string };

  // Synchronous file operations - not ideal
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const fs = require('fs');
  fs.writeFileSync('/tmp/user.json', JSON.stringify(userData));

  return userData.name;
}

export function calculateTotal(items: number[]): number {
  let total = 0;
  for (let i = 0; i < items.length; i++) {
    total += items[i];
  }
  return total;
}

export class UserService {
  private users: Map<string, unknown> = new Map();

  addUser(id: string, data: unknown): void {
    this.users.set(id, data);
  }

  getUser(id: string): unknown {
    return this.users.get(id);
  }

  // Missing error handling
  async fetchUser(id: string): Promise<unknown> {
    const response = await fetch(`/api/users/${id}`);
    return response.json();
  }
}
