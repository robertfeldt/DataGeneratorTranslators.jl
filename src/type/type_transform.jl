# returns only subtypes we can translate
# TODO (throughout) check which context should be used for this since generator is evaluated when the context of a module
function translatable_subtypes(dt::DataType)
	filter(subtypes(current_module(), dt)) do subdt
		# !(subdt <: DataGenerators.Generator) &&
		!(subdt <: Vararg)
	end
end


function transform_type_ast(ast::ASTNode)

	# extract primary datatypes and upper bound datatypes of typevars in the parsed type as well as supplemental types
	supporteddts = isempty(ast.args[:supporteddts]) ? extract_primary_datatypes(ast.args[:type]) : ast.args[:supporteddts]
	# remove Any from this list as tree is too big - instead user could specify required subtypes of Any in supplemental types
	# remove Vararg since it is handled in a special way within Tuple
	supporteddts = filter(t -> !(t in [Any; Vararg;]), supporteddts)
	# merge datatypes upwards (i.e. if A subsumes B, take just B)
	supporteddts = merge_datatypes_up(supporteddts)
	# this now gives a non-overlapping list of the datatypes we will support in the dt tree
	if isempty(supporteddts)
		error("No supportable datatypes passed in type nor supplemental types")
	end

	if !all(t -> t in DIRECTLY_SUPPORTED_TYPES, nonabstract_descendents(supporteddts; subtypefn=translatable_subtypes))
		# if some of the nonabstract descendent types of the supported types cannot be constructed directly 
		# then we add Tuple and Type as supported types in order to support the signatures of constructor methods
		supporteddts = merge_datatypes_up([supporteddts; Tuple; Type])
	end

	valuenode = create_value_node()
	datatypenode = create_datatype_node()
	typenode = create_type_node()
	methodnode = create_method_node()
	dtrootnode = create_dt_root_node(supporteddts)
	ast.children = [valuenode; datatypenode; typenode; methodnode; dtrootnode;]

	add_reference(ast, :valueref, valuenode) do node
		(node.func == :method) ||
		((node.func == :cm) && !haskey(node.args, :method) && (node.args[:datatype] == Tuple))
	end

	add_reference(ast, :datatyperef, datatypenode) do node
		(node.func == :value) || 
		(node.func == :type) ||
		((node.func == :dt) && (node.args[:datatype] == Type)) ||
		((node.func == :cm) && !haskey(node.args, :method) && (node.args[:datatype] in [DataType; Union;]))
	end

	add_reference(ast, :typeref, typenode) do node
		(node.func == :datatype) ||
		(node.func == :method) ||
		((node.func == :dt) && (node.args[:datatype] == Type))
	end

	add_reference(ast, :dtref, dtrootnode) do node
		(node.func == :value) || 
		(node.func == :type)
	end

	add_reference(ast, :methodref, methodnode) do node
		(node.func == :cm) && haskey(node.args, :method)
	end

	add_choose(ast, :dt, :dtref) do node
		(node.func == :dt) && node.args[:abstract]
	end

	add_choose(ast, :cm, :cmref) do node
		(node.func == :dt) && !node.args[:abstract]
	end

  	push!(ast.refs, valuenode) # add type node as reference to root to enable reachability check

end


create_value_node() = ASTNode(:value)

create_datatype_node() = ASTNode(:datatype)

create_type_node() = ASTNode(:type)

create_method_node() = ASTNode(:method)

function create_dt_root_node(supporteddts::Vector{DataType})
	# supporteddttree is the minimal partial subtree of primary datatypes that includes the supported datatypes, and remains
	# rooted at Any
	# the handlable_subtypes function filters the subtypes to those we can handle
	supporteddttree = datatype_tree(supporteddts; subtypefn = translatable_subtypes)
	create_dt_node(Any, supporteddttree, supporteddts)
end

function create_dt_node(t::DataType, supporteddttree::Dict{DataType, Vector{DataType}}, supporteddts::Vector{DataType})
	primarydt = primary_datatype(t)
	primaryisabstract = is_abstract(primarydt)
	node = ASTNode(:dt)
	node.args[:name] = primarydt.name.name
	node.args[:datatype] = primarydt
	node.args[:abstract] = primaryisabstract
	@assert primaryisabstract == !isempty(supporteddttree[primarydt])
	if primaryisabstract
		primarysubtypes = supporteddttree[primarydt]
		node.children = map(st->create_dt_node(st, supporteddttree, supporteddts), primarysubtypes)
	else 
		if !(primarydt in DIRECTLY_SUPPORTED_TYPES) # TODO could also add partially supported constructor methods even in the case of a translator constructed alternative
			append!(node.children, map(cm -> create_constructor_method_node(cm, primarydt), partially_supported_constructor_methods(primarydt, supporteddts)))
		end
		if isempty(node.children)
			push!(node.children, create_constructor_method_node(primarydt))
		end
	end
	node
end

function create_constructor_method_node(cm::SimplifiedMethod, primarydt::DataType)
	node = ASTNode(:cm)
	node.args[:method] = cm
	node.args[:datatype] = primarydt
	node
end

function create_constructor_method_node(primarydt::DataType)
	node = ASTNode(:cm)
	node.args[:datatype] = primarydt
	node
end

function add_choose(predicate::Function, node::ASTNode, childfunc::Symbol, reffunc::Symbol)
	for child in node.children
		add_choose(predicate, child, childfunc, reffunc)
	end
	if predicate(node)
		chooseablenodes = filter(child -> child.func == childfunc, node.children)
		if !isempty(chooseablenodes)
			choosenode = ASTNode(:choose)
			for chooseablenode in chooseablenodes
				refnode = ASTNode(reffunc)
				refnode.refs = [chooseablenode;]
				push!(choosenode.children, refnode)
			end
			push!(node.children, choosenode)
		end
	end
end

function add_reference(predicate::Function, node::ASTNode, func::Symbol, target::ASTNode)
	for child in node.children
		add_reference(predicate, child, func, target)
	end
	if predicate(node)
		refnode = ASTNode(func)
		refnode.refs = [target;]
		push!(node.children, refnode)
	end
end

