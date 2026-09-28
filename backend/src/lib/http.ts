export class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}
export const bad = (m: string) => new HttpError(400, m);
export const forbidden = (m = 'forbidden') => new HttpError(403, m);
export const notFound = (m = 'not found') => new HttpError(404, m);
