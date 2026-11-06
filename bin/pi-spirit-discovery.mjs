// Pi and Prime share this thin adapter; the reader owns all evidence semantics.
import { join } from 'node:path';
export function registerSpiritDiscovery(pi, { root, runtime, Type }) {
  if (!['pi', 'prime'].includes(runtime)) throw new Error('invalid discovery adapter');
  pi.registerTool({
    name: 'egregore_discover_capabilities', label: 'Egregore capabilities',
    description: 'Inspect local installed-file evidence and separately authenticated spirit capabilities. Read-only; does not grant or execute work.',
    parameters: Type.Object({ operation: Type.Union(['capabilities.list','capabilities.find','capabilities.describe','capabilities.explain','system.explain'].map(Type.Literal)),
      query: Type.Optional(Type.String({ maxLength: 200 })), id: Type.Optional(Type.String({ maxLength: 160 })) }, { additionalProperties: false }),
    async execute(_id, params) {
      // JSON is argv data; the fixed adapter never accepts a root or runtime selector.
      if (!params || typeof params !== 'object' || Array.isArray(params)
        || !['capabilities.list','capabilities.find','capabilities.describe','capabilities.explain','system.explain'].includes(params.operation)) throw new Error('invalid discovery query');
      const args = [join(root, 'bin', `spirit-discovery-${runtime}.sh`), params.operation];
      const allowed = params.operation === 'capabilities.find' ? ['operation','query']
        : ['capabilities.describe','capabilities.explain'].includes(params.operation) ? ['operation','id']
        : params.operation === 'system.explain' && Object.hasOwn(params,'id') ? ['operation','id'] : ['operation'];
      if (Object.keys(params).sort().join() !== allowed.sort().join()) throw new Error('invalid discovery query');
      for (const [field, limit] of [['query', 200], ['id', 160]]) {
        if (Object.hasOwn(params, field) && (typeof params[field] !== 'string' || !params[field].trim()
          || Buffer.from(params[field], 'utf8').toString('utf8') !== params[field]
          || Buffer.byteLength(params[field]) > limit || /[\x00-\x1f\x7f]/.test(params[field]))) throw new Error('invalid discovery query');
      }
      if (Object.hasOwn(params,'query')) args.push(params.query);
      if (Object.hasOwn(params,'id')) args.push(params.id);
      const response = await pi.exec('bash', args, { timeout: 15000 });
      if (Number(response.code ?? response.status ?? 0) !== 0) throw new Error('discovery is unavailable');
      let value;
      try { value = JSON.parse(response.stdout); } catch { throw new Error('discovery is unavailable'); }
      if (value.schema !== 'egregore.capability-query/v1') throw new Error('discovery is unavailable');
      return { content: [{ type: 'text', text: JSON.stringify(value) }], details: value };
    },
  });
}
