import { startStack, type Stack } from "./support/stack";

let stack: Stack | null = null;

export default async function setup() {
  stack = await startStack();
  process.env.UI_BASE_URL = stack?.baseUrl ?? "";
  process.env.UI_REST_LOG = process.env.E2E_REST_LOG ?? "";
  return async () => { await stack?.stop(); };
}
