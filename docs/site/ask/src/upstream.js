import { Failure, boundedText, parseJSON } from './policy.js';

const CLAUDE = 'https://api.anthropic.com/v1/messages';
const TYPES = new Set(['invalid_request_error', 'authentication_error', 'billing_error',
  'permission_error', 'not_found_error', 'conflict_error', 'request_too_large',
  'rate_limit_error', 'api_error', 'timeout_error', 'overloaded_error']);

function metadata(response, body) {
  const result = { service: 'claude', httpStatus: response.status };
  const id = response.headers.get('request-id') || body?.request_id;
  if (typeof id === 'string' && /^req_[A-Za-z0-9_]{1,128}$/.test(id)) result.requestId = id;
  for (const [name, header] of [
    ['retryAfterSeconds', 'retry-after'], ['inputTokenLimit', 'anthropic-ratelimit-input-tokens-limit'],
    ['tokenLimit', 'anthropic-ratelimit-tokens-limit'], ['tokensRemaining', 'anthropic-ratelimit-tokens-remaining'],
    ['inputTokensRemaining', 'anthropic-ratelimit-input-tokens-remaining'],
    ['outputTokenLimit', 'anthropic-ratelimit-output-tokens-limit'],
    ['outputTokensRemaining', 'anthropic-ratelimit-output-tokens-remaining'],
    ['requestsRemaining', 'anthropic-ratelimit-requests-remaining']
  ]) {
    const value = response.headers.get(header);
    if (value !== null && /^\d{1,12}(\.\d{1,3})?$/.test(value)) result[name] = Number(value);
  }
  if (!response.ok) {
    result.errorType = TYPES.has(body?.error?.type) ? body.error.type : 'unknown_error';
    const message = typeof body?.error?.message === 'string' ? body.error.message : '';
    result.category = body?.error?.details?.error_code === 'enforced_spend_limit_reached'
      || /specified (workspace )?API usage limits|credit balance|spend limit/i.test(message) ? 'billing_limit'
      : /input tokens per minute|input token rate/i.test(message) ? 'input_token_rate'
      : /output tokens per minute|output token rate/i.test(message) ? 'output_token_rate'
      : /thinking.*cannot be modified|Invalid.*signature.*thinking|tools.*differs/i.test(message) ? 'thinking_history'
      : /tool_use|tool_result|tool definition/i.test(message) ? 'tool_history' : result.errorType;
  }
  return result;
}

function providerFailure(details) {
  const message = details.category === 'billing_limit' || details.errorType === 'billing_error'
    ? 'Claude API billing or spending limits blocked this request. The maintainer needs to check the Console.'
    : details.httpStatus === 429 ? 'Claude API rate limit reached. Wait briefly before sending a new message.'
    : details.httpStatus === 529 || details.httpStatus === 503 ? 'Claude is temporarily overloaded. Please try again later.'
    : [401, 403].includes(details.httpStatus) ? 'Claude API access was rejected. The maintainer needs to check the configuration.'
    : details.httpStatus === 400 ? 'Claude rejected the assistant request. The maintainer needs to inspect the saved error.'
    : details.category === 'timeout' ? 'The Claude request timed out. It was not retried.'
    : 'The Claude API request failed. Please try again later.';
  const error = new Failure(502, message);
  error.upstream = details;
  return error;
}

export async function remoteJSON(url, options, fetcher, limit = 32_768, timeoutMS = 35_000) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMS);
  try {
    // Reject redirects without forwarding credentials to another destination.
    const response = await fetcher(url, { ...options, signal: controller.signal, redirect: 'manual' });
    if (!response.ok) {
      if (url !== CLAUDE) throw new Failure(502, 'The upstream service is unavailable. Try later.');
      let body;
      try { body = parseJSON(await boundedText(response.body, 8192)); } catch { /* metadata still survives */ }
      throw providerFailure(metadata(response, body));
    }
    const data = parseJSON(await boundedText(response.body, limit));
    if (url === CLAUDE && data && typeof data === 'object' && !Array.isArray(data)) {
      data.upstream = metadata(response, data);
    }
    return data;
  } catch (error) {
    if (url !== CLAUDE || error instanceof Failure) throw error;
    throw providerFailure({ service: 'claude', httpStatus: null,
      errorType: controller.signal.aborted ? 'timeout_error' : 'transport_error',
      category: controller.signal.aborted ? 'timeout' : 'transport' });
  } finally { clearTimeout(timeout); }
}
