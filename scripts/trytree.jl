using Random
using Distributions

# The goal of this script is to generate a set of hierarchical data structures
# for testing. These data structures use the module ObservedState in the
# src/ObservedState/ directory. There are several steps to creating these
# data structures.
#
#  1. Use a finite tree automata to create a hierarchy of types
#     where these types don't specify the exact parametric type.
#     For instance, for an ObservedArray{Int,3,Symbol}, this finite tree
#     automata will put an `:array` into the hierarchy. We can figure out
#     the rest at a later stage.
#
#     a) The fundamental tree data structure is a Pair that represents
#        a base type as `first()` and the contained Vector{Any} as `last()`.
#
#     b) Generation of the automata uses probabilistic rules that encode
#        the capability of one type to hold another.
#
#     c) A critical step is retaining only unique trees.
#
#  2. Given a particular finite tree automata, decide the exact parametrized
#     type of each member and name of members that are properties.
#
#     a) This uses a new tree representation. This tree uses a struct to define
#        a node. That struct has members: (`stype::Symbol`, `type::DataType`,
#        `name::String`, `type_params::Vector{DataType}`, `children::Vector{Any}`).
#
#     b) A random generator creates names and decides exact types using rules
#        for each container type. An example of a rule is that an `ObservedArray`
#        must have an index that is an NTuple of one Int, two Ints, or three Ints.
#        For properties, names can be random sequences of five letters as long
#        as two names within a property aren't the same.
#
#     c) The output of this step is a specification for the hierarchy.
#
#  3. Provide a function to instantiate the hierarchy of types. This will also
#     create a hierarchy of non-Observed types. That is, when the data structure
#     under test has an `Addressed` member, the non-Observed version will have
#     a typical struct. When there is an `ObservedDict`, the non-Observed
#     will have a `Dict`. Every `Addressed` type can be a simple `mutable struct`
#     in the non-Observed version.
#
#  4. Provide a function to populate the hierarchy of types with members.
#     This function will also populate the non-Observed hierarchy.
#     Every container that is not an `Addressed` will contain zero-to-three of whatever
#     it contains, even if they are other containers.
#
#  5. Unit tests will now take as input the specification of the hierarchy.
#     With that specification, they can read and write randomly and check
#     that observation works and all functions work.
#

function add_tree(tree, lead, state)
    index = copy(lead)
    treetop = tree
    while !isempty(index)
        head = popfirst!(index)
        head_idx = findfirst(x -> first(x) == head, treetop)
        treetop = last(treetop[head_idx])
    end
    push!(treetop, state => Any[])
end


function generate_hierarchy(rng)
    # Given a type of the `key`, it can contain the types in `value`.
    follows = Dict(
        :base => [:primitive, :array, :dict, :set, :addressed, :param],
        :array => [:primitive, :array, :dict, :set, :addressed],
        :dict => [:primitive, :array, :dict, :set, :addressed],
        :set => [:primitive],
        :addressed => [:primitive, :array, :dict, :set, :addressed],
    )
    leaves = Dict{Symbol,Vector{Symbol}}()
    for cont_key in keys(follows)
        leaves[cont_key] = [:primitive]
    end
    leaves[:base] = [:primitive, :param]
    pcontinue = 0.2
    # This is the range of how many types can be contained.
    # :base and :addressed act like structs.
    # :primitive, :set, and :param are always leaf nodes.
    # :array and :dict have one type for their Value types.
    hazard_arity = Dict(
        :base => 1:5,
        :primitive => 0:0,
        :array => 1:1,
        :dict => 1:1,
        :set => 0:0,
        :addressed => 1:5,
        :param => 0:0,
    )
    tree = [:base => Any[]]
    leads = [[:base]]
    terminals = Vector{Vector{Symbol}}()
    while !isempty(leads)
        lead = splice!(leads, rand(rng, 1:length(leads)))
        state = lead[end]
        if !isempty(follows[state])
            more = rand(rng, Bernoulli(pcontinue)) == 1
            if more
                arity = hazard_arity[state]
                if arity[end] > 1
                    child_cnt = rand(rng, arity)
                else
                    child_cnt = 1
                end
                for child_idx in 1:child_cnt
                    add_val = rand(rng, follows[state])
                    push!(leads, vcat(lead, [add_val]))
                    add_tree(tree, lead, add_val)
                end
            else
                add_tree(tree, lead, :primitive)
                push!(terminals, lead)
            end
        end
    end
    return (tree=tree, terminals=terminals)
end

# Given a tree of containers and primitives,
# choose the types of how they will be indexed.
function assign_indices(tree, rng)
    # Breadth-first-search

end


# This looks at a tree that represents types to create and reorders it
# so that we can create the instances in-order and they will define
# the tree.
function creation_order(tree)::Vector{Any} end


function print_tree(tree, indent=0)
    prefix = " " ^ indent
    for pair in tree
        println(prefix, first(pair))
        print_tree(last(pair), indent + 2)
    end
end

function make_trees(n, rng)
    seen = Set{Any}()
    i = 1
    while i <= 10
        (hh, terminals) = generate_hierarchy(rng)
        println(repeat("=", 80))
        if hh ∉ seen
            push!(seen, hh)
            print_tree(hh)
            i += 1
        end
    end
    return seen
end

rng = Xoshiro(234245)
make_trees(10, rng)
