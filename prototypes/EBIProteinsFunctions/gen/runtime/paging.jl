"""
    Pages{R<:Request}

Iterator over the pages of a search, returned by `paginate`.
"""
struct Pages{R<:Request}
    request::R
    offset::Int
    size::Int
end

"""
    paginate(req::Request)

Iterate over a search one decoded page at a time, starting at the request's `offset` (default 0) with pages of its `size` (default 100), until a page comes back short or empty.
Only requests from operations with `offset` and `size` parameters (`Pageable`) have a method.

    for page in paginate(proteins(gene = "INS", reviewed = true, size = 50, send = false))
        ...
    end
"""
paginate(req::Pageable) = Pages(req, _getquery(req.query, "offset", 0), _getquery(req.query, "size", 100))

Base.IteratorSize(::Type{<:Pages}) = Base.SizeUnknown()

function Base.iterate(p::Pages, offset = p.offset)
    offset === nothing && return nothing
    page = _send(_page(p.request, offset, p.size), true)
    _lastpage(page, p.size) && return nothing
    return page, _fullpage(page, p.size) ? offset + p.size : nothing
end
