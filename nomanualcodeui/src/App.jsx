import { useEffect, useState } from 'react'
import { createPerson, deletePerson, listPersons, updatePerson } from './api/persons.js'
import './App.css'

const EMPTY_FORM = { firstName: '', lastName: '', email: '', dateOfBirth: '' }

function App() {
    const [persons, setPersons] = useState([])
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState(null)
    const [filter, setFilter] = useState('')
    const [form, setForm] = useState(EMPTY_FORM)
    const [editingId, setEditingId] = useState(null)
    const [saving, setSaving] = useState(false)

    async function load(lastName) {
        setLoading(true)
        setError(null)
        try {
            setPersons(await listPersons(lastName))
        } catch (err) {
            setError(`Could not load persons: ${err.message}`)
        } finally {
            setLoading(false)
        }
    }

    // Initial fetch; `loading` already starts as true, so only set state once the request settles.
    useEffect(() => {
        let ignore = false
        listPersons()
            .then((data) => !ignore && setPersons(data))
            .catch((err) => !ignore && setError(`Could not load persons: ${err.message}`))
            .finally(() => !ignore && setLoading(false))
        return () => {
            ignore = true
        }
    }, [])

    function handleChange(e) {
        setForm({ ...form, [e.target.name]: e.target.value })
    }

    function resetForm() {
        setForm(EMPTY_FORM)
        setEditingId(null)
    }

    function startEdit(person) {
        setEditingId(person.id)
        setForm({
            firstName: person.firstName,
            lastName: person.lastName,
            email: person.email,
            dateOfBirth: person.dateOfBirth ?? '',
        })
    }

    async function handleSubmit(e) {
        e.preventDefault()
        setSaving(true)
        setError(null)
        const payload = { ...form, dateOfBirth: form.dateOfBirth || null }
        try {
            if (editingId) {
                const updated = await updatePerson(editingId, payload)
                setPersons(persons.map((p) => (p.id === editingId ? updated : p)))
            } else {
                const created = await createPerson(payload)
                setPersons([...persons, created])
            }
            resetForm()
        } catch (err) {
            setError(`Could not save person: ${err.message}`)
        } finally {
            setSaving(false)
        }
    }

    async function handleDelete(person) {
        if (!window.confirm(`Delete ${person.firstName} ${person.lastName}?`)) return
        setError(null)
        try {
            await deletePerson(person.id)
            setPersons(persons.filter((p) => p.id !== person.id))
            if (editingId === person.id) resetForm()
        } catch (err) {
            setError(`Could not delete person: ${err.message}`)
        }
    }

    function handleSearch(e) {
        e.preventDefault()
        load(filter.trim() || undefined)
    }

    function clearSearch() {
        setFilter('')
        load()
    }

    return (
        <main className="persons">
            <h1>Persons</h1>

            {error && (
                <div className="alert" role="alert">
                    {error}
                    <button type="button" className="link" onClick={() => setError(null)}>Dismiss</button>
                </div>
            )}

            <section className="card">
                <h2>{editingId ? 'Edit person' : 'Add person'}</h2>
                <form className="person-form" onSubmit={handleSubmit}>
                    <label>
                        First name
                        <input name="firstName" value={form.firstName} onChange={handleChange} required />
                    </label>
                    <label>
                        Last name
                        <input name="lastName" value={form.lastName} onChange={handleChange} required />
                    </label>
                    <label>
                        Email
                        <input name="email" type="email" value={form.email} onChange={handleChange} required />
                    </label>
                    <label>
                        Date of birth
                        <input name="dateOfBirth" type="date" value={form.dateOfBirth} onChange={handleChange} />
                    </label>
                    <div className="actions">
                        <button type="submit" disabled={saving}>
                            {saving ? 'Saving…' : editingId ? 'Update' : 'Create'}
                        </button>
                        {editingId && (
                            <button type="button" className="secondary" onClick={resetForm}>Cancel</button>
                        )}
                    </div>
                </form>
            </section>

            <section className="card">
                <form className="search" onSubmit={handleSearch}>
                    <input
                        placeholder="Filter by last name"
                        value={filter}
                        onChange={(e) => setFilter(e.target.value)}
                    />
                    <button type="submit">Search</button>
                    <button type="button" className="secondary" onClick={clearSearch}>Clear</button>
                </form>

                {loading ? (
                    <p>Loading…</p>
                ) : persons.length === 0 ? (
                    <p>No persons found.</p>
                ) : (
                    <div className="table-wrap">
                        <table>
                            <thead>
                                <tr>
                                    <th>ID</th>
                                    <th>First name</th>
                                    <th>Last name</th>
                                    <th>Email</th>
                                    <th>Date of birth</th>
                                    <th />
                                </tr>
                            </thead>
                            <tbody>
                                {persons.map((p) => (
                                    <tr key={p.id} className={p.id === editingId ? 'editing' : undefined}>
                                        <td>{p.id}</td>
                                        <td>{p.firstName}</td>
                                        <td>{p.lastName}</td>
                                        <td>{p.email}</td>
                                        <td>{p.dateOfBirth ?? '—'}</td>
                                        <td className="row-actions">
                                            <button type="button" className="secondary" onClick={() => startEdit(p)}>Edit</button>
                                            <button type="button" className="danger" onClick={() => handleDelete(p)}>Delete</button>
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                )}
            </section>
        </main>
    )
}

export default App
