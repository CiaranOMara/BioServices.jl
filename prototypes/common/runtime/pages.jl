_lastpage(page, size) = page === nothing || isempty(page)
_fullpage(page, size) = !(page isa AbstractVector) || length(page) >= size
