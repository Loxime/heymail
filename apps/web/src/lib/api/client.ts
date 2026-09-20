export class ApiError extends Error {
  public constructor(
    public readonly status: number,
    public readonly code: string | null,
    message: string,
  ) {
    super(message)

    this.name = 'ApiError'
  }
}

async function parseError(
  response: Response,
): Promise<ApiError> {
  let message =
    `HeyMail API returned HTTP ${response.status}.`

  let code: string | null = null

  try {
    const payload =
      await response.json() as {
        error?: {
          code?: string
          message?: string
        }
      }

    if (
      typeof payload.error?.code
      === 'string'
    ) {
      code = payload.error.code
    }

    if (
      typeof payload.error?.message
      === 'string'
    ) {
      message = payload.error.message
    }
  } catch {
    // Keep generic bounded error.
  }

  return new ApiError(
    response.status,
    code,
    message,
  )
}

async function request<T>(
  path: string,
  init: RequestInit,
): Promise<T> {
  const response = await fetch(
    path,
    {
      credentials: 'same-origin',
      ...init,
      headers: {
        Accept: 'application/json',
        ...init.headers,
      },
    },
  )

  if (!response.ok) {
    throw await parseError(response)
  }

  if (response.status === 204) {
    return undefined as T
  }

  return await response.json() as T
}

function jsonBody(
  body: unknown,
): {
  headers: Record<string, string>
  body: string
} {
  return {
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  }
}

export function apiGet<T>(
  path: string,
): Promise<T> {
  return request<T>(
    path,
    {
      method: 'GET',
    },
  )
}

export function apiPost<T>(
  path: string,
  body?: unknown,
  headers: Record<string, string> = {},
): Promise<T> {
  const encoded =
    body === undefined
      ? null
      : jsonBody(body)

  return request<T>(
    path,
    {
      method: 'POST',
      headers: {
        ...(encoded?.headers ?? {}),
        ...headers,
      },
      body: encoded?.body,
    },
  )
}

export function apiPostText<T>(
  path: string,
  body: string,
  contentType: string,
): Promise<T> {
  return request<T>(
    path,
    {
      method: 'POST',
      headers: {
        'Content-Type': contentType,
      },
      body,
    },
  )
}

export function apiPatch<T>(
  path: string,
  body: unknown,
): Promise<T> {
  const encoded = jsonBody(body)

  return request<T>(
    path,
    {
      method: 'PATCH',
      headers: encoded.headers,
      body: encoded.body,
    },
  )
}

export function apiDelete<T>(
  path: string,
  body?: unknown,
): Promise<T> {
  const encoded =
    body === undefined
      ? null
      : jsonBody(body)

  return request<T>(
    path,
    {
      method: 'DELETE',
      headers: encoded?.headers,
      body: encoded?.body,
    },
  )
}
