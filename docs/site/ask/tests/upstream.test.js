import assert from 'node:assert/strict';
import test from 'node:test';
import { remoteJSON } from '../src/upstream.js';

const endpoint = 'https://api.anthropic.com/v1/messages';

test('successful Claude calls expose only selected numeric rate headers and a bounded request ID', async () => {
  const result = await remoteJSON(endpoint, {}, async () => Response.json({ content: [], upstream: { secret: 'forged' } },
    { headers: { 'request-id': 'req_safe_id', 'anthropic-ratelimit-input-tokens-limit': '40000',
      'anthropic-ratelimit-output-tokens-remaining': 'invalid', 'x-secret': 'secret-value' } }));
  assert.deepEqual(result.upstream, { service: 'claude', httpStatus: 200, requestId: 'req_safe_id', inputTokenLimit: 40000 });
});

test('billing caps, overload and request rejection have distinct messages without exposing provider text', async () => {
  for (const [status, type, details, pattern] of [
    [429, 'rate_limit_error', { error_code: 'enforced_spend_limit_reached' }, /billing or spending/],
    [529, 'overloaded_error', {}, /overloaded/],
    [400, 'invalid_request_error', {}, /rejected the assistant request/]
  ]) {
    await assert.rejects(remoteJSON(endpoint, {}, async () => Response.json({
      error: { type, details, message: 'provider secret raw text' }
    }, { status })), error => {
      assert.match(error.message, pattern); assert.equal(error.status, 502);
      assert.equal(error.upstream.httpStatus, status);
      assert.ok(!JSON.stringify(error.upstream).includes('provider secret'));
      return true;
    });
  }
});

test('oversized or malformed provider errors retain safe HTTP metadata and never retry', async () => {
  let calls = 0;
  await assert.rejects(remoteJSON(endpoint, {}, async () => { calls++;
    return new Response('x'.repeat(9000), { status: 503, headers: { 'request-id': 'not a valid id' } });
  }), error => {
    assert.deepEqual(error.upstream, { service: 'claude', httpStatus: 503, errorType: 'unknown_error', category: 'unknown_error' });
    return true;
  });
  assert.equal(calls, 1);
});

test('transport failures discard exception text and are not retried', async () => {
  let calls = 0;
  await assert.rejects(remoteJSON(endpoint, {}, async () => { calls++; throw Error('private-token-value'); }), error => {
    assert.equal(error.upstream.errorType, 'transport_error');
    assert.equal(JSON.stringify(error).includes('private-token-value'), false);
    return true;
  });
  assert.equal(calls, 1);
});

test('provider redirects never forward credentials or follow destinations', async () => {
  let calls = 0;
  await assert.rejects(remoteJSON(endpoint, { headers: { 'x-api-key': 'secret-key' } }, async (url, options) => {
    calls++; assert.equal(url, endpoint); assert.equal(options.redirect, 'manual');
    return new Response(null, { status: 302, headers: { Location: 'https://attacker.example' } });
  }), error => error.upstream.httpStatus === 302);
  assert.equal(calls, 1);
});
