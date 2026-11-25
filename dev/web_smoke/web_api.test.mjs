import assert from 'node:assert/strict';
import { copyFile, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { test } from 'node:test';

// Run the real bridge with an in-memory wllama. No model or Wasm is needed.
test('the web bridge maps decisions and realtime', async (t) => {
    const dir = await mkdtemp(join(tmpdir(), 'fllama-web-api-'));
    const state = { loads: [], decisions: [], sessions: [] };
    class Wllama {
        constructor(_paths, config) { this.logger = config.logger; }
        setCompat() {}
        isModelLoaded() { return Boolean(this.config); }
        getNumThreads() { return this.config.n_threads; }
        getLoadedContextInfo() { return { n_vocab: 100, has_audio_stream: true }; }
        modelManager = { getModels: async () => [] };
        async loadModelFromUrl(source, config) {
            if (source === 'missing') throw new Error('missing model');
            this.logger.warn('load log');
            if (source?.url === 'slow') await new Promise(resolve => { state.finishLoad = resolve; });
            this.config = config;
            state.loads.push({ source, config });
        }
        async exit() { this.config = null; }
        async createSystemOne(body, signal) {
            this.logger.log('decision log');
            state.decisions.push(body);
            if (body.error) throw Object.assign(new Error(body.error.message), body.error);
            if (body.wait) await new Promise(resolve => signal.addEventListener('abort', resolve, { once: true }));
            return { answers: { q: { type: 'noul', noul: 0.9 } }, usage: { input_tokens: 20, output_tokens: 0 } };
        }
        async createRealtimeSession(options) {
            const session = { options, sent: [], closed: false };
            state.sessions.push(session);
            let close;
            const closed = new Promise(resolve => { close = resolve; });
            let serverError;
            return {
                async *events() {
                    yield { type: 'session.created', session: { type: 'transcription' } };
                    await closed;
                    if (serverError) yield serverError;
                },
                async send(event) {
                    session.sent.push(event);
                    if (event.type === 'end-from-server') {
                        serverError = { type: 'error', error: { message: 'The conversation does not fit in the context.' } };
                        close();
                        throw new Error('Realtime session is closed');
                    }
                },
                async close() { session.closed = true; close(); },
            };
        }
    }
    try {
        globalThis.window = globalThis;
        globalThis.TestWllama = Wllama;
        await mkdir(join(dir, 'wllama'));
        await writeFile(join(dir, 'wllama', 'index.js'), 'export const Wllama = globalThis.TestWllama;');
        await copyFile(new URL('../../lib/web/fllama_web_init.js', import.meta.url), join(dir, 'bridge.mjs'));
        await import(pathToFileURL(join(dir, 'bridge.mjs')));
        const request = { modelPath: 'model', modelMmprojPath: 'projector', contextSize: 0, numThreads: 2, numGpuLayers: 0 };
        const start = (body, overrides = {}, logger) => {
            let id;
            const response = new Promise(resolve => {
                id = fllamaDecideJs({ ...request, ...overrides }, JSON.stringify(body),
                    (text, error) => resolve(JSON.parse(error ?? text)), logger);
            });
            return { id, response };
        };

        await t.test('decision body, load settings, model reuse, and logger', async () => {
            const body = { state: 'a state', questions: { q: { type: 'noul', instructions: 'OK?' } }, files: ['data:image/png;base64,AA=='] };
            const logs = [];
            assert.deepEqual((await start(body, {}, line => logs.push(line)).response).answers.q, { type: 'noul', noul: 0.9 });
            await start(body).response;
            assert.deepEqual(state.decisions, [body, body]);
            assert.deepEqual(logs, ['load log', 'decision log']);
            assert.equal(state.loads.length, 1);
            const { source, config } = state.loads[0];
            assert.deepEqual(source, { url: 'model', mmprojUrl: 'projector' });
            assert.deepEqual([config.n_ctx, config.n_batch, config.n_ubatch, config.n_threads, config.n_gpu_layers], [4096, 4096, 4096, 2, 0]);
        });
        await t.test('decision error types and cancellation', async () => {
            for (const [serverErrorType, message, type] of [
                ['exceed_context_size_error', 'context', 'exceed_context_size'],
                ['invalid_request_error', 'bad question', 'invalid_request'],
                ['not_supported_error', 'wrong model', 'not_supported'],
                ['server_error', 'Compute error', 'backend'],
            ]) {
                assert.deepEqual(await start({ error: { serverErrorType, message } }).response, { type, message });
            }
            assert.equal((await start({}, { modelPath: 'missing', modelMmprojPath: null }).response).type, 'model_load');
            const decision = start({ wait: true });
            fllamaCancelInferenceJs(decision.id);
            assert.equal((await decision.response).type, 'cancelled');
        });
        await t.test('realtime holds the model, sends queued events in order, and closes once', async () => {
            const events = [];
            let handle;
            let waitForCreated;
            const created = new Promise(resolve => { waitForCreated = resolve; });
            const closed = new Promise(resolve => {
                handle = fllamaRealtimeOpenJs({ ...request }, 'intent=%74ranscription&intent=transcription', text => {
                    const event = JSON.parse(text);
                    events.push(event);
                    if (event.type === 'session.created') waitForCreated();
                    if (event.type === 'fllama.realtime.closed') resolve();
                });
            });
            const update = { type: 'session.update', session: { type: 'transcription' } };
            const commit = { type: 'input_audio_buffer.commit', final: true };
            assert.equal(handle.send(JSON.stringify(update)), true);
            assert.equal(handle.send(JSON.stringify(commit)), true);
            await created;
            const loads = state.loads.length;
            const waiting = start({}, { modelPath: 'other' });
            const cancelling = start({}, { modelPath: 'cancelled-while-waiting' });
            fllamaCancelInferenceJs(cancelling.id);
            assert.equal((await cancelling.response).type, 'cancelled');
            assert.equal(state.loads.length, loads);
            const session = state.sessions.at(-1);
            assert.deepEqual(session.options, { intent: 'transcription' });
            assert.deepEqual(session.sent, [update, commit]);
            handle.close();
            handle.close();
            assert.equal(handle.send('{}'), false);
            await closed;
            assert.equal(session.closed, true);
            assert.deepEqual(events.at(-1), { type: 'fllama.realtime.closed', reason: 'client' });
            assert.equal(events.length, 2);
            await waiting.response;
            assert.equal(state.loads.length, loads + 1);
        });
        await t.test('closing realtime does not wait for a shared load', async () => {
            let eventCount = 0;
            let handle;
            const closed = new Promise(resolve => {
                handle = fllamaRealtimeOpenJs({ ...request, modelPath: 'slow' }, null, text => {
                    eventCount++;
                    resolve(JSON.parse(text));
                });
            });
            // Wait for the stub to block inside the model load.
            await new Promise(resolve => setImmediate(resolve));
            assert.equal(typeof state.finishLoad, 'function');
            handle.close();
            assert.deepEqual(await closed, { type: 'fllama.realtime.closed', reason: 'client' });
            state.finishLoad();
            await new Promise(resolve => setImmediate(resolve));
            assert.equal(eventCount, 1);
        });
        await t.test('realtime delivers the terminal server error once', async () => {
            const events = [];
            const closed = new Promise(resolve => {
                const handle = fllamaRealtimeOpenJs({ ...request }, null, text => {
                    const event = JSON.parse(text);
                    events.push(event);
                    if (event.type === 'fllama.realtime.closed') resolve(event);
                });
                handle.send(JSON.stringify({ type: 'end-from-server' }));
            });
            assert.equal((await closed).reason, 'server');
            assert.deepEqual(events.map(event => event.type), ['session.created', 'error', 'fllama.realtime.closed']);
        });
    } finally {
        delete globalThis.TestWllama;
        delete globalThis.window;
        await rm(dir, { recursive: true, force: true });
    }
});
