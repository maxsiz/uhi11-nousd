import { IS_DEMO } from "./wagmi";

export class NotDeployedError extends Error {
  constructor(chain: string) {
    super(`noUSD contracts are not deployed on ${chain} yet.`);
  }
}

/**
 * Sends a transaction. Demo mode stands in for the wallet confirmation with a delay; real mode needs
 * the deployed addresses, which are not wired yet, so it refuses with a readable error.
 */
export function sendTx(chain: string, ms = 1300): Promise<void> {
  if (!IS_DEMO) return Promise.reject(new NotDeployedError(chain));
  return new Promise((resolve) => setTimeout(resolve, ms));
}
