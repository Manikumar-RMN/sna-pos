import { startCluster, type Cluster } from "./support/cluster";

let cluster: Cluster | null = null;

export default async function setup() {
  cluster = await startCluster();
  process.env.E2E_PG_PORT = cluster ? String(cluster.port) : "";
  return async () => { cluster?.stop(); };
}
