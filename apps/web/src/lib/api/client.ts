export class ApiError extends Error {
  public constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message)

    this.name = 'ApiError'
  }
}

export async function apiGet<T>(
  path: string,
): Promise<T> {
  const response =
    await fetch(
      path,
      {
        method: 'GET',

        headers: {
          Accept: 'application/json',
        },

        credentials: 'same-origin',
      },
    )

  if (!response.ok) {
    let message =
      `HeyMail API returned HTTP ${response.status}.`

    try {
      const payload =
        await response.json() as {
          error?: {
            message?: string
          }
        }

      if (
        typeof payload.error?.message
        === 'string'
      ) {
        message =
          payload.error.message
      }
    } catch {
      // Keep bounded generic error.
    }

    throw new ApiError(
      response.status,
      message,
    )
  }

  return await response.json() as T
}
