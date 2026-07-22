@with_kw_noshow struct _Token
    text::String
    start::Int
    stop::Int
    line::Int
    column::Int
end

@with_kw_noshow struct _SNode
    atom::Union{Nothing,String} = nothing
    items::Vector{_SNode} = _SNode[]
    start::Int = 0
    stop::Int = 0
    line::Int = 1
    column::Int = 1
end

_isatom(n::_SNode) = !isnothing(n.atom)
_head(n::_SNode) = isempty(n.items) || !_isatom(n.items[1]) ? "" : lowercase(n.items[1].atom)
_atom(n::_SNode, default="") = _isatom(n) ? n.atom : default

function _tokens(source::AbstractString)
    out = _Token[]
    i = firstindex(source); line = 1; col = 1
    while i <= lastindex(source)
        c = source[i]
        if c == ';'
            while i <= lastindex(source) && source[i] != '\n'
                i = nextind(source, i); col += 1
            end
        elseif isspace(c)
            if c == '\n'; line += 1; col = 1 else col += 1 end
            i = nextind(source, i)
        elseif c == '(' || c == ')'
            push!(out, _Token(text=string(c), start=i-1, stop=i, line=line, column=col))
            i = nextind(source, i); col += 1
        else
            begin_i=i; begin_col=col
            while i <= lastindex(source) && !isspace(source[i]) && source[i] != '(' && source[i] != ')' && source[i] != ';'
                i = nextind(source, i); col += 1
            end
            stop = prevind(source, i)
            push!(out, _Token(text=lowercase(String(source[begin_i:stop])),
                start=begin_i-1, stop=i-1, line=line, column=begin_col))
        end
    end
    out
end

function _sexprs(source::AbstractString, document::String)
    toks = _tokens(source); cursor = Ref(1); diagnostics = Diagnostic[]
    function one()
        cursor[] > length(toks) && return nothing
        t = toks[cursor[]]
        if t.text == "("
            cursor[] += 1; children = _SNode[]
            while cursor[] <= length(toks) && toks[cursor[]].text != ")"
                child = one(); isnothing(child) || push!(children, child)
            end
            if cursor[] > length(toks)
                push!(diagnostics, Diagnostic(code="PDDLICA-PARSE-001",
                    message="unclosed parenthesis", location=SourceSpan(document=document,
                    start_byte=t.start, end_byte=t.stop, start_line=t.line,
                    start_column=t.column, end_line=t.line, end_column=t.column+1)))
                return _SNode(items=children, start=t.start, stop=t.stop, line=t.line, column=t.column)
            end
            close = toks[cursor[]]; cursor[] += 1
            _SNode(items=children, start=t.start, stop=close.stop, line=t.line, column=t.column)
        elseif t.text == ")"
            push!(diagnostics, Diagnostic(code="PDDLICA-PARSE-002",
                message="unexpected closing parenthesis")); cursor[] += 1; nothing
        else
            cursor[] += 1
            _SNode(atom=t.text, start=t.start, stop=t.stop, line=t.line, column=t.column)
        end
    end
    roots = _SNode[]
    while cursor[] <= length(toks)
        node = one(); isnothing(node) || push!(roots, node)
    end
    roots, diagnostics
end

_id(parts...) = join(lowercase.(string.(parts)), "/")
_num(s) = occursin(r"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?(?:/\d+)?$"i, s)

function _typed_parameters(node::_SNode)
    atoms = [_atom(x) for x in node.items]
    out = Any[]; pending = String[]; i = 1
    while i <= length(atoms)
        if atoms[i] == "-" && i < length(atoms)
            typ = atoms[i+1]
            for name in pending
                push!(out, Dict{String,Any}("name" => lstrip(name, '?'), "type" => typ))
            end
            empty!(pending); i += 2
        else
            push!(pending, atoms[i]); i += 1
        end
    end
    for name in pending
        push!(out, Dict{String,Any}("name" => lstrip(name, '?'), "type" => "object"))
    end
    out
end

function _value(node::_SNode; ports=Set{String}())
    if _isatom(node)
        s = node.atom
        s == "self" && return Dict{String,Any}("kind" => "self")
        startswith(s, "?") && return Dict{String,Any}("kind" => "variable", "name" => lstrip(s, '?'))
        _num(s) && return Dict{String,Any}("kind" => "number", "value" => s)
        return Dict{String,Any}("kind" => "symbol", "name" => s)
    end
    h = _head(node)
    args = node.items[2:end]
    if h in ("+", "-", "*", "/", "min", "max")
        return Dict{String,Any}("kind" => "arithmetic", "operator" => h,
            "arguments" => Any[_value(a; ports=ports) for a in args])
    elseif length(args) == 1 && !_isatom(args[1]) && length(args[1].items) == 1 &&
           _atom(args[1].items[1]) in ports
        return Dict{String,Any}("kind" => "port_field", "field" => h,
            "port" => Dict{String,Any}("instance" => Dict("anchor" => "self", "segments" => Any[]),
                "port" => _atom(args[1].items[1])))
    else
        return Dict{String,Any}("kind" => "call", "name" => h,
            "arguments" => Any[_value(a; ports=ports) for a in args])
    end
end

function _formula(node::_SNode; ports=Set{String}())
    if _isatom(node)
        node.atom == "true" && return Dict{String,Any}("kind" => "boolean", "value" => true)
        node.atom == "false" && return Dict{String,Any}("kind" => "boolean", "value" => false)
        return Dict{String,Any}("kind" => "atom", "name" => node.atom, "arguments" => Any[])
    end
    h = _head(node); args = node.items[2:end]
    if h in ("and", "or")
        Dict{String,Any}("kind" => h, "items" => Any[_formula(a; ports=ports) for a in args])
    elseif h == "not"
        Dict{String,Any}("kind" => "not", "item" => _formula(args[1]; ports=ports))
    elseif h == "imply"
        Dict{String,Any}("kind" => "imply", "antecedent" => _formula(args[1]; ports=ports),
            "consequent" => _formula(args[2]; ports=ports))
    elseif h in ("=", "!=", "<", "<=", ">", ">=")
        Dict{String,Any}("kind" => "compare", "operator" => h,
            "left" => _value(args[1]; ports=ports), "right" => _value(args[2]; ports=ports))
    elseif h == "present"
        Dict{String,Any}("kind" => "present", "component" => _value(args[1]; ports=ports))
    elseif h in ("forall", "exists")
        Dict{String,Any}("kind" => h, "parameters" => _typed_parameters(args[1]),
            "body" => _formula(args[2]; ports=ports))
    else
        Dict{String,Any}("kind" => "atom", "name" => h,
            "arguments" => Any[_value(a; ports=ports) for a in args])
    end
end

function _target(node::_SNode; ports=Set{String}())
    v = _value(node; ports=ports)
    v["kind"] == "call" || return v
    v
end

function _effect(node::_SNode; ports=Set{String}())
    _isatom(node) && return Dict{String,Any}("kind" => "set_atom",
        "atom" => Dict("name" => node.atom, "arguments" => Any[]), "value" => true)
    h = _head(node); args = node.items[2:end]
    if h == "and"
        Dict{String,Any}("kind" => "and", "items" => Any[_effect(a; ports=ports) for a in args])
    elseif h == "not"
        a = args[1]; Dict{String,Any}("kind" => "set_atom",
            "atom" => Dict("name" => _head(a), "arguments" => Any[_value(x; ports=ports) for x in a.items[2:end]]),
            "value" => false)
    elseif h in ("assign", "increase", "decrease", "scale-up", "scale-down")
        Dict{String,Any}("kind" => replace(h, '-' => '_'),
            "target" => _target(args[1]; ports=ports), "value" => _value(args[2]; ports=ports))
    elseif h in ("create", "remove")
        Dict{String,Any}("kind" => h, "component" => _value(args[1]; ports=ports))
    else
        Dict{String,Any}("kind" => "set_atom",
            "atom" => Dict("name" => h, "arguments" => Any[_value(x; ports=ports) for x in args]),
            "value" => true)
    end
end

function _fields(node::_SNode)
    d = Dict{String,_SNode}(); i = 3
    while i <= length(node.items)
        key = _atom(node.items[i])
        if startswith(key, ":") && i < length(node.items)
            d[key] = node.items[i+1]; i += 2
        else
            i += 1
        end
    end
    d
end

function _behavior(node::_SNode, owner, ports; kind=_head(node))
    name = _atom(node.items[2]); fields = _fields(node)
    params = haskey(fields, ":parameters") ? _typed_parameters(fields[":parameters"]) : Any[]
    pre = haskey(fields, ":precondition") ? _formula(fields[":precondition"]; ports=ports) :
        Dict{String,Any}("kind" => "boolean", "value" => true)
    idkind = kind == ":method" ? "method" : replace(kind, ":" => "")
    id = isnothing(owner) ? _id("domain", idkind, name) : _id("domain", "component", owner, idkind, name)
    if kind == ":process"
        effect_node = get(fields, ":effect", _SNode(items=_SNode[]))
        raw = _head(effect_node) == "and" ? effect_node.items[2:end] : [effect_node]
        effects = Any[]
        for e in raw
            eh = _head(e); eh in ("increase", "decrease") || continue
            rhs = e.items[3]
            if !_isatom(rhs) && _head(rhs) == "*" && any(_atom(x) == "#t" for x in rhs.items[2:end])
                vals = [x for x in rhs.items[2:end] if _atom(x) != "#t"]
                rhs = length(vals) == 1 ? vals[1] : _SNode(items=vcat([_SNode(atom="*")], vals))
            end
            push!(effects, Dict{String,Any}("operator" => eh,
                "target" => _target(e.items[2]; ports=ports), "rate" => _value(rhs; ports=ports)))
        end
        return Dict{String,Any}("id" => id, "name" => name, "parameters" => params,
            "precondition" => pre, "effects" => effects)
    end
    eff = haskey(fields, ":effect") ? _effect(fields[":effect"]; ports=ports) :
        Dict{String,Any}("kind" => "and", "items" => Any[])
    Dict{String,Any}("id" => id, "name" => name, "parameters" => params,
        "precondition" => pre, "effect" => eff)
end

function _connector(node::_SNode)
    name = _atom(node.items[2]); fields = Any[]
    for child in node.items[3:end]
        h = _head(child)
        h in (":potential", ":flow") || continue
        push!(fields, Dict{String,Any}("name" => _atom(child.items[2]),
            "category" => h[2:end], "value_type" => "number"))
    end
    Dict{String,Any}("id" => _id("domain", "connector", name), "name" => name, "fields" => fields)
end

function _component(node::_SNode)
    name = _atom(node.items[2]); variables = Any[]; ports_out = Any[]
    requirements = Any[]; methods = Any[]; events = Any[]; processes = Any[]
    subs = Any[]; connections = Any[]
    # Ports are collected first so expression lowering can recognize field syntax.
    for sec in node.items[3:end]
        _head(sec) == ":ports" || continue
        i = 2
        while i <= length(sec.items)
            decl = sec.items[i]; pname = _isatom(decl) ? _atom(decl) : _head(decl)
            i += 1
            i <= length(sec.items) && _atom(sec.items[i]) == "-" && (i += 1)
            i > length(sec.items) && break
            ctype = _atom(sec.items[i]); i += 1; presence = "required"
            if i + 1 <= length(sec.items) && _atom(sec.items[i]) == ":presence"
                presence = _atom(sec.items[i+1]); i += 2
            end
            push!(ports_out, Dict{String,Any}("id" => _id("domain", "component", name, "port", pname),
                "name" => pname, "connector_type" => ctype, "presence" => presence))
        end
    end
    portnames = Set(String(p["name"]) for p in ports_out)
    for sec in node.items[3:end]
        h = _head(sec)
        if h == ":variables"
            i = 2
            while i <= length(sec.items)
                decl = sec.items[i]; vname = _isatom(decl) ? _atom(decl) : _head(decl); i += 1
                i <= length(sec.items) && _atom(sec.items[i]) == "-" && (i += 1)
                i > length(sec.items) && break
                typ = _atom(sec.items[i]); i += 1; static = false
                if i <= length(sec.items) && _atom(sec.items[i]) == ":static"; static=true; i += 1 end
                push!(variables, Dict{String,Any}("id" => _id("domain", "component", name, "variable", vname),
                    "name" => vname, "parameters" => Any[], "value_type" => typ, "static" => static))
            end
        elseif h == ":requirement"
            push!(requirements, Dict{String,Any}("id" => _id("domain", "component", name,
                "requirement", length(requirements)), "formula" => _formula(sec.items[2]; ports=portnames)))
        elseif h in (":methods", ":events", ":processes")
            dest = h == ":methods" ? methods : h == ":events" ? events : processes
            for b in sec.items[2:end]
                push!(dest, _behavior(b, name, portnames; kind=_head(b)))
            end
        elseif h == ":components"
            for s in sec.items[2:end]
                vals = [_atom(x) for x in s.items]
                dash = findfirst(==("-"), vals)
                isnothing(dash) || push!(subs, Dict{String,Any}(
                    "id" => _id("domain", "component", name, "subcomponent", vals[1]),
                    "name" => vals[1], "component_type" => vals[dash+1]))
            end
        elseif h == ":connections"
            for c in sec.items[2:end]
                push!(connections, _connection(c, name, length(connections)))
            end
        end
    end
    Dict{String,Any}("id" => _id("domain", "component", name), "name" => name,
        "variables" => variables, "ports" => ports_out, "requirements" => requirements,
        "methods" => methods, "events" => events, "processes" => processes,
        "subcomponents" => subs, "connections" => connections)
end

function _port_ref(n::_SNode; anchor="problem")
    vals = [_atom(x) for x in n.items]
    length(vals) >= 2 || return Dict{String,Any}("instance" => Dict("anchor" => anchor, "segments" => Any[]), "port" => "")
    Dict{String,Any}("instance" => Dict("anchor" => anchor, "segments" => vals[1:end-1]), "port" => vals[end])
end

function _connection(n::_SNode, owner=nothing, index=0)
    anchor = isnothing(owner) ? "problem" : "self"
    Dict{String,Any}("id" => isnothing(owner) ? _id("problem", "connection", index) :
        _id("domain", "component", owner, "connection", index),
        "ports" => Any[_port_ref(x; anchor=anchor) for x in n.items[2:end]])
end

function _types(sec::_SNode)
    params = _typed_parameters(_SNode(items=sec.items[2:end])); out = Any[]
    for p in params
        push!(out, Dict{String,Any}("id" => _id("domain", "type", p["name"]),
            "name" => p["name"], "parent" => p["type"]))
    end
    out
end

function _domain(root::_SNode)
    length(root.items) >= 2 && _head(root) == "define" || throw(ArgumentError("domain must start with (define ...)"))
    header = root.items[2]; _head(header) == "domain" || throw(ArgumentError("expected domain header"))
    name = _atom(header.items[2])
    d = Dict{String,Any}("id" => "domain", "name" => name, "requirements" => Any[],
        "types" => Any[], "constants" => Any[], "predicates" => Any[], "functions" => Any[],
        "derived_predicates" => Any[], "connector_types" => Any[], "component_types" => Any[],
        "actions" => Any[], "durative_actions" => Any[], "events" => Any[], "processes" => Any[])
    for sec in root.items[3:end]
        h = _head(sec)
        if h == ":requirements"
            d["requirements"] = Any[_atom(x) for x in sec.items[2:end]]
        elseif h == ":types"
            d["types"] = _types(sec)
        elseif h == ":connector-type"
            push!(d["connector_types"], _connector(sec))
        elseif h == ":component-type"
            push!(d["component_types"], _component(sec))
        elseif h in (":action", ":event", ":process")
            dest = h == ":action" ? "actions" : h == ":event" ? "events" : "processes"
            push!(d[dest], _behavior(sec, nothing, Set{String}(); kind=h))
        elseif h == ":predicates"
            for p in sec.items[2:end]
                push!(d["predicates"], Dict{String,Any}("id" => _id("domain", "predicate", _head(p)),
                    "name" => _head(p), "parameters" => _typed_parameters(_SNode(items=p.items[2:end]))))
            end
        elseif h == ":functions"
            # Accept the common one-declaration-per-list spelling.
            for f in sec.items[2:end]
                _isatom(f) && continue
                push!(d["functions"], Dict{String,Any}("id" => _id("domain", "function", _head(f)),
                    "name" => _head(f), "parameters" => _typed_parameters(_SNode(items=f.items[2:end])),
                    "returns" => "number"))
            end
        end
    end
    d
end

function _problem(root::_SNode)
    _head(root) == "define" || throw(ArgumentError("problem must start with (define ...)"))
    header=root.items[2]; _head(header) == "problem" || throw(ArgumentError("expected problem header"))
    name=_atom(header.items[2]); domain=""; objects=Any[]; components=Any[]; connections=Any[]; init=Any[]
    goal=Dict{String,Any}("kind" => "boolean", "value" => true)
    for sec in root.items[3:end]
        h=_head(sec)
        if h == ":domain"; domain=_atom(sec.items[2])
        elseif h == ":objects"
            for p in _typed_parameters(_SNode(items=sec.items[2:end]))
                push!(objects, Dict{String,Any}("id" => _id("problem", "object", p["name"]),
                    "name" => p["name"], "type" => p["type"]))
            end
        elseif h == ":components"
            for c in sec.items[2:end]
                vals=[_atom(x) for x in c.items]; dash=findfirst(==("-"), vals)
                isnothing(dash) && continue
                present=true; pi=findfirst(==(":present"), vals)
                !isnothing(pi) && pi < length(vals) && (present = vals[pi+1] == "true")
                push!(components, Dict{String,Any}("id" => _id("problem", "component", vals[1]),
                    "name" => vals[1], "component_type" => vals[dash+1], "present" => present))
            end
        elseif h == ":connections"
            for c in sec.items[2:end]; push!(connections, _connection(c, nothing, length(connections))) end
        elseif h == ":init"
            for (i, e) in enumerate(sec.items[2:end])
                if _head(e) == "="
                    push!(init, Dict{String,Any}("id" => _id("problem", "init", i-1), "kind" => "equality",
                        "left" => _value(e.items[2]), "right" => _value(e.items[3])))
                elseif _head(e) == "not"
                    a=e.items[2]; push!(init, Dict{String,Any}("id" => _id("problem", "init", i-1),
                        "kind" => "fact", "atom" => Dict("name" => _head(a),
                        "arguments" => Any[_value(x) for x in a.items[2:end]]), "value" => false))
                else
                    push!(init, Dict{String,Any}("id" => _id("problem", "init", i-1),
                        "kind" => "fact", "atom" => Dict("name" => _head(e),
                        "arguments" => Any[_value(x) for x in e.items[2:end]]), "value" => true))
                end
            end
        elseif h == ":goal"; goal=_formula(sec.items[2])
        end
    end
    Dict{String,Any}("id" => "problem", "name" => name, "domain" => domain,
        "objects" => objects, "components" => components, "connections" => connections,
        "init" => init, "goal" => goal, "constraints" => Any[])
end

function _source(source_or_path::AbstractString)
    isfile(source_or_path) ? read(source_or_path, String) : String(source_or_path)
end

function parse_model(domain_source::AbstractString, problem_source::AbstractString;
                     logical_domain_name=nothing, logical_problem_name=nothing, parser=:julia)
    parser == :julia || return ParseResult(diagnostics=[Diagnostic(code="PDDLICA-PARSE-900",
        message="this package implements only the native Julia parser")])
    ds=_source(domain_source); ps=_source(problem_source)
    dn=isnothing(logical_domain_name) ? (isfile(domain_source) ? basename(domain_source) : "domain.plca") : logical_domain_name
    pn=isnothing(logical_problem_name) ? (isfile(problem_source) ? basename(problem_source) : "problem.plca") : logical_problem_name
    dr, dd = _sexprs(ds, "domain-source"); pr, pd = _sexprs(ps, "problem-source")
    diags=vcat(dd,pd)
    (length(dr)==1 && length(pr)==1) || push!(diags, Diagnostic(code="PDDLICA-PARSE-003",
        message="domain and problem must each contain exactly one top-level form"))
    isempty(diags) || return ParseResult(diagnostics=diags)
    try
        domain=_domain(dr[1]); problem=_problem(pr[1])
        domain["name"] == problem["domain"] || push!(diags, Diagnostic(code="PDDLICA-PARSE-004",
            message="problem names domain '$(problem["domain"])', expected '$(domain["name"])'"))
        isempty(diags) || return ParseResult(diagnostics=diags)
        sm=Dict{String,Any}("documents" => Any[
            Dict("id"=>"domain-source","role"=>"domain","logical_name"=>dn,
                "content_digest"=>"sha256:"*bytes2hex(sha256(ds))),
            Dict("id"=>"problem-source","role"=>"problem","logical_name"=>pn,
                "content_digest"=>"sha256:"*bytes2hex(sha256(ps)))],
            "locations" => Dict{String,Any}())
        doc=PDDLicaDocument(language=Dict{String,Any}("name"=>"pddlica","version"=>"0.5",
            "host_language"=>"pddl","host_features"=>Any["pddl2.1","pddl+","pddl3"]),
            domain=domain, problem=problem, source_map=sm)
        ParseResult(document=doc)
    catch err
        ParseResult(diagnostics=[Diagnostic(code="PDDLICA-PARSE-005",
            message=sprint(showerror, err))])
    end
end
