function _getquery(query, key, default)
    i = findfirst(p -> first(p) == key, query)
    return i === nothing ? default : Base.parse(Int, last(query[i]))
end
