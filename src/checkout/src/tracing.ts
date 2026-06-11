import { Span, trace, SpanStatusCode, context, propagation } from '@opentelemetry/api';

export const tracer = trace.getTracer('checkout', '1.0.0');
export { SpanStatusCode, context, propagation };

export const setSpanError = (span: Span, error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  span.recordException(error instanceof Error ? error : new Error(message));
  span.setStatus({ code: SpanStatusCode.ERROR, message });
};
