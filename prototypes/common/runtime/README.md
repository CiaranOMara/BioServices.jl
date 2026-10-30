# Runtime pieces

These files are Julia code that the generators copy unchanged into the clients they generate.
Keeping them as real files, rather than strings inside the generators, means they can be read, edited and syntax-checked like any other code.

Each generator lists the pieces it needs, in order, in its `render` function, and joins them with the code it renders from the spec.
The files here are shared by the two HTTP.jl clients, EBIProteinsFunctions and EBIProteinsKwarg:

- `formats.jl`: `Format{S}`, `mime` and `decode`, the response format and how a response is turned into a value.
- `parameters.jl`: the parameter types (`IntParam`, `ListParam`, `IntListParam`) and how values become URL paths and query strings.
- `http.jl`: sending a request with HTTP.jl, retrying HTTP 429, and encoding the request body.
- `pages.jl`: when a page of search results is the last one.

Each client's own pieces are in its `gen/runtime/`.
A file there can also replace one of these, for a client that needs to differ.
The pieces refer to `BASE_URL` and `MIMES`, which the generators render from the spec before them.
