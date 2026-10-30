"""
    Pages{E<:Endpoint, F<:Format}

Iterator over the pages of a search, returned by `paginate`.
"""
struct Pages{E<:Endpoint, F<:Format}
    endpoint::E
    format::F
    offset::Int
    size::Int
end

"""
    paginate(e::Endpoint; accept = defaultformat(e))

Iterate over a search one decoded page at a time, starting at its `offset` (default 0) with pages of its `size` (default 100), until a page comes back short or empty.
Only endpoints with `offset` and `size` fields (`Pageable`) have a method.

    for page in paginate(Proteins(gene = "INS", reviewed = true, size = 50))
        ...
    end
"""
paginate(e::Pageable; accept = defaultformat(e)) =
    Pages(e, Format(accept), something(e.offset, 0), something(e.size, 100))

Base.IteratorSize(::Type{<:Pages}) = Base.SizeUnknown()

function Base.iterate(p::Pages, offset = p.offset)
    offset === nothing && return nothing
    page = _send(_with(p.endpoint; offset, size = p.size), p.format, true)
    _lastpage(page, p.size) && return nothing
    return page, _fullpage(page, p.size) ? offset + p.size : nothing
end
