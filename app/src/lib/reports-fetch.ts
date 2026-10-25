/** Shared database read helper for the report pages that still look rows up by id (the audit page). */
import type { DbErrorLike } from "./db-error";

/** Ids looked up per request (a long list of ids in one request can be refused as too long). */
export const IN_CHUNK = 100;

/** Looks up rows by id in small groups. Stops at the first error. */
export async function inChunks<T>(
  ids: string[],
  run: (chunk: string[]) => PromiseLike<{ data: T[] | null; error: DbErrorLike | null }>,
): Promise<{ rows: T[]; error: DbErrorLike | null }> {
  const rows: T[] = [];
  for (let i = 0; i < ids.length; i += IN_CHUNK) {
    const { data, error } = await run(ids.slice(i, i + IN_CHUNK));
    if (error) return { rows, error };
    rows.push(...(data ?? []));
  }
  return { rows, error: null };
}
