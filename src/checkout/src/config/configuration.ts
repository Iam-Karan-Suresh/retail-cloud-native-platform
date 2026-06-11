
export default () => ({
  persistence: {
    provider: process.env.RETAIL_CHECKOUT_PERSISTENCE_PROVIDER || 'in-memory',
    redis: {
      url: process.env.RETAIL_CHECKOUT_PERSISTENCE_REDIS_URL || '',
      reader: {
        url: process.env.RETAIL_CHECKOUT_PERSISTENCE_REDIS_READER_URL || '',
      },
    },
  },
  endpoints: {
    orders: process.env.RETAIL_CHECKOUT_ENDPOINTS_ORDERS || '',
  },
  shipping: {
    prefix: process.env.RETAIL_CHECKOUT_SHIPPING_NAME_PREFIX || '',
  },
});
