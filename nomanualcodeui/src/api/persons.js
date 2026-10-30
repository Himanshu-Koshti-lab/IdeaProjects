// Thin client for the Spring Boot /api/persons endpoints (proxied by Vite / Express).
const BASE = '/api/persons'

async function request(url, options = {}) {
  const res = await fetch(url, {
    ...options,
    headers: { Accept: 'application/json', ...(options.body && { 'Content-Type': 'application/json' }) },
  })
  if (!res.ok) {
    let message = `${res.status} ${res.statusText}`
    try {
      const body = await res.json()
      message = body.error || body.message || message
    } catch {
      // response had no JSON body
    }
    throw new Error(message)
  }
  return res.status === 204 ? null : res.json()
}

export function listPersons(lastName) {
  const query = lastName ? `?lastName=${encodeURIComponent(lastName)}` : ''
  return request(BASE + query)
}

export function getPerson(id) {
  return request(`${BASE}/${id}`)
}

export function createPerson(person) {
  return request(BASE, { method: 'POST', body: JSON.stringify(person) })
}

export function updatePerson(id, person) {
  return request(`${BASE}/${id}`, { method: 'PUT', body: JSON.stringify(person) })
}

export function deletePerson(id) {
  return request(`${BASE}/${id}`, { method: 'DELETE' })
}
