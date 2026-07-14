function paginate(array, page = 1, limit = 20) {
  const total = array.length;
  const start = (page - 1) * limit;
  const data = array.slice(start, start + limit);
  return { data, total, page: Number(page), limit: Number(limit) };
}

module.exports = { paginate };
