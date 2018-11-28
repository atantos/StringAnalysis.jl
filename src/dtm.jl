# Basic DocumentTermMatrix type
mutable struct DocumentTermMatrix{T}
    dtm::SparseMatrixCSC{T, Int}
    terms::Vector{String}
    column_indices::Dict{String, Int}
end

# Construct a DocumentTermMatrix from a Corpus
# create col index lookup dictionary from a (sorted?) vector of terms
function columnindices(terms::Vector{String})
    column_indices = Dict{String, Int}()
    for (i, term) in enumerate(terms)
        column_indices[term] = i
    end
    return column_indices
end

function DocumentTermMatrix{T}(crps::Corpus,
                               terms::Vector{String}) where T<:Real
    column_indices = columnindices(terms)
    m = length(crps)
    n = length(terms)
    rows = Vector{Int}(undef, 0)
    columns = Vector{Int}(undef, 0)
    values = Vector{T}(undef, 0)
    for (i, doc) in enumerate(crps)
        ngs = ngrams(doc)
        for ngram in keys(ngs)
            j = get(column_indices, ngram, 0)
            v = ngs[ngram]
            if j != 0
                push!(rows, i)
                push!(columns, j)
                push!(values, v)
            end
        end
    end
    if length(rows) > 0
        dtm = sparse(rows, columns, values, m, n)
    else
        dtm = spzeros(T, m, n)
    end
    return DocumentTermMatrix(dtm, terms, column_indices)
end

DocumentTermMatrix(crps::Corpus, terms::Vector{String}) =
    DocumentTermMatrix{DEFAULT_DTM_TYPE}(crps, terms)

DocumentTermMatrix(crps::Corpus, lex::AbstractDict) =
    DocumentTermMatrix(crps, sort(collect(keys(lex))))

DocumentTermMatrix(crps::Corpus) = begin
    isempty(lexicon(crps)) && update_lexicon!(crps)
    DocumentTermMatrix(crps, lexicon(crps))
end

DocumentTermMatrix(dtm::SparseMatrixCSC{T, Int},
                   terms::Vector{String}) where T<:Real =
    DocumentTermMatrix(dtm, terms, columnindices(terms))


# Access the DTM of a DocumentTermMatrix
dtm(d::DocumentTermMatrix) = d.dtm

dtm(crps::Corpus) = dtm(DocumentTermMatrix(crps))


# Term-document matrix
tdm(crps::DocumentTermMatrix) = dtm(crps)' #'

tdm(crps::Corpus) = dtm(crps)' #'


# Produce the signature of a DTM entry for a document
function dtm_entries(d::AbstractDocument,
                     lex::Dict{String, Int};
                     eltype::Type{T}=DEFAULT_DTM_TYPE) where T<:Real
    ngs = ngrams(d)
    indices = Vector{Int}(undef, 0)
    values = Vector{T}(undef, 0)
    terms = sort(collect(keys(lex)))
    column_indices = columnindices(terms)
    for ngram in keys(ngs)
        j = get(column_indices, ngram, 0)
        v = ngs[ngram]
        if j != 0
            push!(indices, j)
            push!(values, v)
        end
    end
    return (indices, values)
end

function dtv(d::AbstractDocument,
             lex::Dict{String, Int};
             eltype::Type{T}=DEFAULT_DTM_TYPE) where T<:Real
    p = length(keys(lex))
    row = zeros(T, p)
    indices, values = dtm_entries(d, lex)
    row[indices] = values
    return row
end

function dtv(crps::Corpus, idx::Int)
    if isempty(crps.lexicon)
        error("Cannot construct a DTV without a pre-existing lexicon")
    elseif idx >= length(crps.documents) || idx < 1
        error("DTV requires the document index in [1,$(length(crps.documents))]")
    else
        return dtv(crps.documents[idx], crps.lexicon)
    end
end

function dtv(d::AbstractDocument)
    error("Cannot construct a DTV without a pre-existing lexicon")
end


# The hash trick: use a hash function instead of a lexicon to determine the
# columns of a DocumentTermMatrix-like encoding of the data
function hash_dtv(d::AbstractDocument,
                  h::TextHashFunction;
                  eltype::Type{T}=DEFAULT_DTM_TYPE) where T<:Real
    p = cardinality(h)
    res = zeros(T, p)
    ngs = ngrams(d)
    for ng in keys(ngs)
        res[index_hash(ng, h)] += ngs[ng]
    end
    return res
end

hash_dtv(d::AbstractDocument;
         cardinality::Int=DEFAULT_CARDINALITY,
         eltype::Type{T}=DEFAULT_DTM_TYPE) where T<:Real =
    hash_dtv(d, TextHashFunction(cardinality), eltype=eltype)

function hash_dtm(crps::Corpus,
                  h::TextHashFunction;
                  eltype::Type{T}=DEFAULT_DTM_TYPE) where T<:Real
    n, p = length(crps), cardinality(h)
    res = zeros(T, n, p)
    for (i, doc) in enumerate(crps)
        res[i, :] = hash_dtv(doc, h, eltype=eltype)
    end
    return res
end


hash_dtm(crps::Corpus; eltype::Type{T}=DEFAULT_DTM_TYPE) where T<:Real =
    hash_dtm(crps, hash_function(crps), eltype=eltype)

hash_tdm(crps::Corpus, eltype::Type{T}=DEFAULT_DTM_TYPE) where T<:Real =
    hash_dtm(crps, eltype=eltype)' #'


# Produce entries for on-line analysis when DTM would not fit in memory
mutable struct EachDTV{S, T<:AbstractDocument}
    corpus::Corpus{T}
end

EachDTV{S}(crps::Corpus{T}) where {S,T} = EachDTV{S,T}(crps)

Base.iterate(edt::EachDTV, state=1) = begin
    if state > length(edt.corpus)
        return nothing
    else
        return next(edt, state)
    end
end

next(edt::EachDTV{S, T}, state::Int) where {S,T} =
    (dtv(edt.corpus.documents[state], lexicon(edt.corpus), eltype=S), state + 1)

each_dtv(crps::Corpus; eltype::Type{S}=DEFAULT_DTM_TYPE) where S<:Real =
    EachDTV{S}(crps)

Base.eltype(::Type{EachDTV{S,T}}) where {S,T} = Vector{S}

Base.length(edt::EachDTV) = length(edt.corpus)

Base.size(edt::EachDTV) = (length(edt.corpus), edt.corpus.h.cardinality)

Base.show(io::IO, edt::EachDTV{S,T}) where {S,T} =
    print(io, "DTV iterator, $(length(edt)) elements of type $(eltype(edt)).")


mutable struct EachHashDTV{S, T<:AbstractDocument}
    corpus::Corpus{T}
end

EachHashDTV{S}(crps::Corpus{T}) where {S,T} = EachHashDTV{S,T}(crps)

Base.iterate(edt::EachHashDTV, state=1) = begin
    if state > length(edt.corpus)
        return nothing
    else
        return next(edt, state)
    end
end

next(edt::EachHashDTV{S,T}, state::Int) where {S,T} =
    (hash_dtv(edt.corpus.documents[state], edt.corpus.h, eltype=S), state + 1)

each_hash_dtv(crps::Corpus; eltype::Type{S}=DEFAULT_DTM_TYPE) where S<:Real =
    EachHashDTV{S}(crps)

Base.eltype(::Type{EachHashDTV{S,T}}) where {S,T} = Vector{S}

Base.length(edt::EachHashDTV) = length(edt.corpus)

Base.size(edt::EachHashDTV) = (length(edt.corpus), edt.corpus.h.cardinality)

Base.show(io::IO, edt::EachHashDTV{S,T}) where {S,T} =
    print(io, "Hash-DTV iterator, $(length(edt)) elements of type $(eltype(edt)).")


## getindex() methods
Base.getindex(dtm::DocumentTermMatrix, k::AbstractString) = dtm.dtm[:, dtm.column_indices[k]]

Base.getindex(dtm::DocumentTermMatrix, i) = dtm.dtm[i]

Base.getindex(dtm::DocumentTermMatrix, i, j) = dtm.dtm[i, j]
