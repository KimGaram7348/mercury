%-----------------------------------------------------------------------------%
% Copyright (C) 1996-2000 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
:- module higher_order.
% Main author: stayl
%
% Specializes calls to higher order or polymorphic predicates where the value
% of one or more higher order, type_info or typeclass_info arguments are known.
%
% Since this creates a new copy of the called procedure I have limited the
% specialization to cases where the called procedure's goal contains less than
% 20 calls and unifications. For predicates above this size the overhead of
% the higher order call becomes less significant while the increase in code
% size becomes significant. The limit can be changed using
% `--higher-order-size-limit'.
%
% If a specialization creates new opportunities for specialization, the
% specialization process will be iterated until no further opportunities arise.
% The specialized version for predicate 'foo' is named 'foo__ho<n>', where n
% is a number that uniquely identifies this specialized version.
%-------------------------------------------------------------------------------

:- interface.

:- import_module hlds_module.
:- import_module io.

:- pred specialize_higher_order(module_info::in, module_info::out,
		io__state::di, io__state::uo) is det.

%-------------------------------------------------------------------------------

:- implementation.

:- import_module hlds_pred, hlds_goal, hlds_data, instmap, (inst).
:- import_module code_util, globals, mode_util, goal_util.
:- import_module type_util, options, prog_data, prog_out, quantification.
:- import_module mercury_to_mercury, inlining, polymorphism, prog_util.
:- import_module special_pred, passes_aux.

:- import_module assoc_list, bool, char, int, list, map, require, set.
:- import_module std_util, string, varset, term.

	% Iterate collecting requests and processing them until there
	% are no more requests remaining.
specialize_higher_order(ModuleInfo0, ModuleInfo) -->
	globals__io_get_globals(Globals),
	{ globals__lookup_bool_option(Globals, optimize_higher_order,
		HigherOrder) },
	{ globals__lookup_bool_option(Globals, type_specialization,
		TypeSpec) },
	{ globals__lookup_bool_option(Globals, user_guided_type_specialization,
		UserTypeSpec) },
	{ globals__lookup_int_option(Globals, higher_order_size_limit,
		SizeLimit) },
	{ Params = ho_params(HigherOrder, TypeSpec,
		UserTypeSpec, SizeLimit, unit) },
	{ map__init(NewPredMap) },
	{ map__init(PredVarMap) },
	{ NewPreds0 = new_preds(NewPredMap, PredVarMap) },
	{ map__init(GoalSizes0) },

	{ module_info_predids(ModuleInfo0, PredIds0) },
	{ module_info_type_spec_info(ModuleInfo0,
		type_spec_info(_, UserSpecPreds, _, _)) },

	%
	% Make sure the user requested specializations are processed first,
	% since we don't want to create more versions if one of these
	% matches.
	%
	{ set__list_to_set(PredIds0, PredIdSet0) },
	{ set__difference(PredIdSet0, UserSpecPreds, PredIdSet) },
	{ set__to_sorted_list(PredIdSet, PredIds) },

	{ set__init(Requests0) },
	{ set__to_sorted_list(UserSpecPreds, UserSpecPredList) },
	{ get_specialization_requests(Params, UserSpecPredList, NewPreds0,
		Requests0, UserRequests, GoalSizes0, GoalSizes1,
		ModuleInfo0, ModuleInfo1) },
	process_requests(Params, UserRequests, Requests1,
		GoalSizes1, 1, NextHOid, NewPreds0, NewPreds1,
		ModuleInfo1, ModuleInfo2),

	%
	% Process all other specialization until no more requests
	% are generated.
	%
	{ get_specialization_requests(Params, PredIds, NewPreds1,
		Requests1, Requests, GoalSizes1, GoalSizes,
		ModuleInfo2, ModuleInfo3) },
	recursively_process_requests(Params, Requests, GoalSizes,
		NextHOid, _, NewPreds1, _NewPreds, ModuleInfo3, ModuleInfo4),

	% Remove the predicates which were used to force the production of
	% user-requested type specializations, since they are not called
	% from anywhere and are no longer needed.
	{ list__foldl(module_info_remove_predicate,
		UserSpecPredList, ModuleInfo4, ModuleInfo) }.

	% Process one lot of requests, returning requests for any
	% new specializations made possible by the first lot.
:- pred process_requests(ho_params::in, set(request)::in, set(request)::out,
	goal_sizes::in, int::in, int::out, new_preds::in, new_preds::out,
	module_info::in, module_info::out,
	io__state::di, io__state::uo) is det.

process_requests(Params, Requests0, NewRequests, GoalSizes,
		NextHOid0, NextHOid, NewPreds0, NewPreds,
		ModuleInfo1, ModuleInfo) -->
	filter_requests(Params, ModuleInfo1, Requests0, GoalSizes, Requests),
	(
		{ Requests = [] }
	->
		{ ModuleInfo = ModuleInfo1 },
		{ NextHOid = NextHOid0 },
		{ NewPreds = NewPreds0 },
		{ set__init(NewRequests) }
	;
		{ set__init(PredProcsToFix0) },
		create_new_preds(Params, Requests, NewPreds0, NewPreds,
			[], NewPredList, PredProcsToFix0, PredProcsToFix,
			NextHOid0, NextHOid, ModuleInfo1, ModuleInfo2),
		{ set__to_sorted_list(PredProcsToFix, PredProcs) },
		{ set__init(NewRequests0) },

		{ fixup_specialized_versions(Params, NewPredList,
			NewPreds, NewRequests0, NewRequests,
			ModuleInfo2, ModuleInfo3) },

		{ fixup_preds(Params, PredProcs, NewPreds,
			ModuleInfo3, ModuleInfo4) },
		{ NewPredList \= [] ->
			% The dependencies have changed, so the
			% dependency graph needs to rebuilt for
			% inlining to work properly.
			module_info_clobber_dependency_info(ModuleInfo4,
				ModuleInfo)
		;
			ModuleInfo = ModuleInfo4
		}
	).

	% Process requests until there are no new requests to process.
:- pred recursively_process_requests(ho_params::in, set(request)::in,
	goal_sizes::in, int::in, int::out, new_preds::in, new_preds::out,
	module_info::in, module_info::out,
	io__state::di, io__state::uo) is det.

recursively_process_requests(Params, Requests0, GoalSizes, NextHOid0, NextHOid,
		NewPreds0, NewPreds, ModuleInfo0, ModuleInfo) -->
	( { set__empty(Requests0) } ->
		{ NextHOid = NextHOid0 },
		{ NewPreds = NewPreds0 },
		{ ModuleInfo = ModuleInfo0 }
	;
		process_requests(Params, Requests0, NewRequests, GoalSizes,
			NextHOid0, NextHOid1, NewPreds0, NewPreds1,
			ModuleInfo0, ModuleInfo1),
		recursively_process_requests(Params, NewRequests, GoalSizes,
			NextHOid1, NextHOid, NewPreds1, NewPreds,
			ModuleInfo1, ModuleInfo)
	).

%-------------------------------------------------------------------------------

:- type request
	---> request(
		pred_proc_id,			% calling pred
		pred_proc_id,			% called pred 
		list(prog_var),			% call args
		list(tvar),			% type variables for which
						% extra type-infos must be 
						% passed from the caller if
						% --typeinfo-liveness is set. 
		list(higher_order_arg),
		list(type),			% argument types in caller
		bool,				% should the interface of 
						% the specialized procedure
						% use typeinfo liveness.
		tvarset,			% caller's typevarset.
		bool,				% is this a user-requested
						% specialization
		context				% context of the call which
						% caused the request to be
						% generated
	).

		% Stores cons_id, index in argument vector, number of 
		% curried arguments of a higher order argument, higher-order
		% curried arguments with known values.
		% For cons_ids other than pred_const and `type_info',
		% the arguments must be constants
:- type higher_order_arg
	---> higher_order_arg(
		cons_id,
	 	int,			% index in argument vector
		int,			% number of curried args
		list(prog_var),		% curried arguments in caller
		list(type),		% curried argument types in caller
		list(higher_order_arg)	% higher-order curried arguments
					% with known values
	).

:- type goal_sizes == map(pred_id, int). 	%stores the size of each
				% predicate's goal used in the heuristic
				% to decide which preds are specialized
		
	% Used to hold the value of known higher order variables.
	% If a variable is not in the map, it does not have a value yet.
:- type pred_vars == map(prog_var, maybe_const). 

	% The list of vars is a list of the curried arguments, which must
	% be explicitly passed to the specialized predicate.
	% For cons_ids other than pred_const and `type_info', the arguments
	% must be constants. For pred_consts and type_infos, non-constant
	% arguments are passed through to any specialised version.
:- type maybe_const --->
		constant(cons_id, list(prog_var))
						% unique possible value
	;	multiple_values			% multiple possible values,
						% cannot specialise.
	.

	% used while traversing goals
:- type higher_order_info 
	---> info(
		pred_vars,	% higher_order variables
		set(request),	% requested versions
		new_preds,	% versions created in
				% previous iterations
				% not changed by traverse_goal
		pred_proc_id,	% pred_proc_id of goal being traversed
		pred_info,	% pred_info of goal being traversed
		proc_info,	% proc_info of goal being traversed
		module_info,	% not changed by traverse_goal
		ho_params,
		changed
	).

:- type ho_params
	---> ho_params(
		bool,		% propagate higher-order constants.
		bool,		% propagate type-info constants.
		bool,		% user-guided type specialization.
		int,		% size limit on requested version.
		unit
	).

:- type new_preds
	---> new_preds(
		map(pred_proc_id, set(new_pred)),
				% versions for each predicate
		map(pred_proc_id, pred_vars)
				% higher-order or constant input variables
				% for a specialised version.
	).

:- type new_pred
	---> new_pred(
		pred_proc_id,		% version pred_proc_id
		pred_proc_id,		% old pred_proc_id
		pred_proc_id,		% requesting caller
		sym_name,		% name 
		list(higher_order_arg),	% specialized args
		list(prog_var),		% unspecialised argument vars in caller
		list(tvar),		% extra typeinfo tvars in caller
		list(type),		% unspecialised argument types
					% in requesting caller
		bool,			% does the interface of the specialized
					% version use type-info liveness
		tvarset,		% caller's typevarset
		bool			% is this a user-specified type
					% specialization
	).

	% Returned by traverse_goal. 
:- type changed
	--->	changed		% Need to requantify goal + check other procs
	;	request		% Need to check other procs
	;	unchanged.	% Do nothing more for this predicate

%-----------------------------------------------------------------------------%
:- pred get_specialization_requests(ho_params::in, list(pred_id)::in,
	new_preds::in, set(request)::in, set(request)::out, goal_sizes::in,
	goal_sizes::out, module_info::in, module_info::out) is det.

get_specialization_requests(_Params, [], _NewPreds, Requests, Requests,
		Sizes, Sizes, ModuleInfo, ModuleInfo).
get_specialization_requests(Params, [PredId | PredIds], NewPreds, Requests0,
		Requests, GoalSizes0, GoalSizes, ModuleInfo0, ModuleInfo) :-
	module_info_preds(ModuleInfo0, Preds0), 
	map__lookup(Preds0, PredId, PredInfo0),
	pred_info_non_imported_procids(PredInfo0, NonImportedProcs),
	(
		NonImportedProcs = [],
		Requests2 = Requests0,
		GoalSizes1 = GoalSizes0,
		ModuleInfo3 = ModuleInfo0
	;
		NonImportedProcs = [ProcId | ProcIds],
		pred_info_procedures(PredInfo0, Procs0),
		map__lookup(Procs0, ProcId, ProcInfo0),
		map__init(PredVars0),
			% first time through we can only specialize call/N
		PredProcId = proc(PredId, ProcId),
		Info0 = info(PredVars0, Requests0, NewPreds, PredProcId,
			PredInfo0, ProcInfo0, ModuleInfo0, Params, unchanged),
		traverse_goal(Info0, Info),
		Info = info(_, Requests1, _, _, PredInfo1, ProcInfo,
				ModuleInfo1, _, _),
		proc_info_goal(ProcInfo, Goal1),
		goal_size(Goal1, GoalSize),
		map__set(GoalSizes0, PredId, GoalSize, GoalSizes1),
		map__det_update(Procs0, ProcId, ProcInfo, Procs1),
		traverse_other_procs(Params, PredId, ProcIds,
			ModuleInfo1, ModuleInfo2, PredInfo1, PredInfo2,
			NewPreds, Requests1, Requests2, Procs1, Procs),
		pred_info_set_procedures(PredInfo2, Procs, PredInfo),
		map__det_update(Preds0, PredId, PredInfo, Preds),
		module_info_set_preds(ModuleInfo2, Preds, ModuleInfo3)
	),
	get_specialization_requests(Params, PredIds, NewPreds,
		Requests2, Requests, GoalSizes1, GoalSizes,
		ModuleInfo3, ModuleInfo).

		% This is called when the first procedure of a pred was 
		% changed. It fixes up all the other procs, ignoring the
		% goal_size and requests that come out, since that information
		% has already been collected. 
:- pred traverse_other_procs(ho_params::in, pred_id::in, list(proc_id)::in,
	module_info::in, module_info::out, pred_info::in, pred_info::out,
	new_preds::in, set(request)::in, set(request)::out,
	proc_table::in, proc_table::out) is det. 

traverse_other_procs(_Params, _PredId, [], Module, Module, PredInfo, PredInfo,
		_, Requests, Requests, Procs, Procs).
traverse_other_procs(Params, PredId, [ProcId | ProcIds],
		ModuleInfo0, ModuleInfo, PredInfo0, PredInfo, NewPreds,
		Requests0, Requests, Procs0, Procs) :-
	map__init(PredVars0),
	map__lookup(Procs0, ProcId, ProcInfo0),
	Info0 = info(PredVars0, Requests0, NewPreds, proc(PredId, ProcId),
			PredInfo0, ProcInfo0, ModuleInfo0, Params, unchanged),
	traverse_goal(Info0, Info),
	Info = info(_, Requests1, _,_,PredInfo1,ProcInfo,ModuleInfo1,_,_),
	map__det_update(Procs0, ProcId, ProcInfo, Procs1),
	traverse_other_procs(Params, PredId, ProcIds, ModuleInfo1, ModuleInfo,
		PredInfo1, PredInfo, NewPreds,
		Requests1, Requests, Procs1, Procs).
	
%-------------------------------------------------------------------------------
	% Goal traversal

:- pred traverse_goal(higher_order_info::in, higher_order_info::out) is det.

traverse_goal -->
	{ MustRecompute = no },
	traverse_goal(MustRecompute).

:- pred traverse_goal(bool::in, higher_order_info::in,
		higher_order_info::out) is det.

traverse_goal(MustRecompute, Info0, Info) :-
	Info0 = info(_, B, NewPreds0, PredProcId, E, ProcInfo0, G, H, I),
	NewPreds0 = new_preds(_, PredVarMap),

	% Lookup the initial known bindings of the variables if this
	% procedure is a specialised version.
	( map__search(PredVarMap, PredProcId, PredVars) ->
		Info1 = info(PredVars, B, NewPreds0, PredProcId,
				E, ProcInfo0, G, H, I)
	;
		Info1 = Info0
	),
	proc_info_goal(ProcInfo0, Goal0),
	traverse_goal_2(Goal0, Goal, Info1, Info2),
	fixup_proc_info(MustRecompute, Goal, Info2, Info).

:- pred fixup_proc_info(bool::in, hlds_goal::in,
		higher_order_info::in, higher_order_info::out) is det.

fixup_proc_info(MustRecompute, Goal0, Info0, Info) :-
	Info0 = info(A, B, C, D, E, ProcInfo0, ModuleInfo0, H, Changed),
	( (Changed = changed ; MustRecompute = yes) ->
		proc_info_set_goal(ProcInfo0, Goal0, ProcInfo1),
		requantify_proc(ProcInfo1, ProcInfo2),
		proc_info_goal(ProcInfo2, Goal2),
		RecomputeAtomic = no,
		proc_info_get_initial_instmap(ProcInfo2, ModuleInfo0, InstMap),
		proc_info_vartypes(ProcInfo2, VarTypes),
		recompute_instmap_delta(RecomputeAtomic, Goal2, Goal3,
			VarTypes, InstMap, ModuleInfo0, ModuleInfo),
		proc_info_set_goal(ProcInfo2, Goal3, ProcInfo),
		Info = info(A, B, C, D, E, ProcInfo, ModuleInfo, H, Changed)
	;
		Info = Info0
	).

	% Traverses the goal collecting higher order variables for which 
	% the value is known, and specializing calls and adding
	% specialization requests to the request_info structure. 
	% The first time through the only predicate we can specialize
	% is call/N. The pred_proc_id is that of the current procedure,
	% used to find out which procedures need fixing up later.
:- pred traverse_goal_2(hlds_goal::in, hlds_goal::out, 
	higher_order_info::in, higher_order_info::out) is det.

traverse_goal_2(conj(Goals0) - Info, conj(Goals) - Info) -->
	list__map_foldl(traverse_goal_2, Goals0, Goals).

traverse_goal_2(par_conj(Goals0, SM) - Info, par_conj(Goals, SM) - Info) -->
		% traverse_disj treats its list of goals as independent
		% rather than specifically disjoint, so we can use it
		% to process a list of independent parallel conjuncts.
	traverse_disj(Goals0, Goals).

traverse_goal_2(disj(Goals0, SM) - Info, disj(Goals, SM) - Info) -->
	traverse_disj(Goals0, Goals).

		% a switch is treated as a disjunction
traverse_goal_2(switch(Var, CanFail, Cases0, SM) - Info,
		switch(Var, CanFail, Cases, SM) - Info) -->
	traverse_cases(Cases0, Cases).

		% check whether this call could be specialized
traverse_goal_2(Goal0, Goal) -->
	{ Goal0 = generic_call(GenericCall, Args, _, _) - GoalInfo }, 
	(
		{
			GenericCall = higher_order(Var, _, _),
			MaybeMethod = no
		;
			GenericCall = class_method(Var, Method, _, _),
			MaybeMethod = yes(Method)
		}
	->
		maybe_specialize_higher_order_call(Var, MaybeMethod,
			Args, Goal0, Goals),
		{ conj_list_to_goal(Goals, GoalInfo, Goal) }
	;
		{ Goal = Goal0 }
	).

		% check whether this call could be specialized
traverse_goal_2(Goal0, Goal) -->
	{ Goal0 = call(_,_,_,_,_,_) - _ }, 
	maybe_specialize_call(Goal0, Goal).

		% if-then-elses are handled as disjunctions
traverse_goal_2(Goal0, Goal) -->
	{ Goal0 = if_then_else(Vars, Cond0, Then0, Else0, SM) - GoalInfo },
	get_pre_branch_info(PreInfo),
	traverse_goal_2(Cond0, Cond),
	traverse_goal_2(Then0, Then),
	get_post_branch_info(PostThenInfo),
	set_pre_branch_info(PreInfo),
	traverse_goal_2(Else0, Else),
	get_post_branch_info(PostElseInfo),
	{ Goal = if_then_else(Vars, Cond, Then, Else, SM) - GoalInfo },
	{ merge_post_branch_infos(PostThenInfo, PostElseInfo, PostInfo) },
	set_post_branch_info(PostInfo).

traverse_goal_2(not(NegGoal0) - Info, not(NegGoal) - Info) -->
	traverse_goal_2(NegGoal0, NegGoal).

traverse_goal_2(some(Vars, CanRemove, Goal0) - Info,
		some(Vars, CanRemove, Goal) - Info) -->
	traverse_goal_2(Goal0, Goal).

traverse_goal_2(Goal, Goal) -->
	{ Goal = pragma_c_code(_, _, _, _, _, _, _) - _ }.

traverse_goal_2(Goal, Goal) -->
	{ Goal = unify(_, _, _, Unify, _) - _ }, 
	check_unify(Unify).

traverse_goal_2(bi_implication(_, _) - _, _) -->
	% these should have been expanded out by now
	{ error("traverse_goal_2: unexpected bi_implication") }.

		% To process a disjunction, we process each disjunct with the
		% specialization information before the goal, then merge the
		% results to give the specialization information after the
		% disjunction.
		%
		% This code is used both for disjunction and parallel
		% conjunction.

:- pred traverse_disj(hlds_goals::in, hlds_goals::out,
	higher_order_info::in, higher_order_info::out) is det.

traverse_disj([], []) --> [].
traverse_disj([Goal0 | Goals0], [Goal | Goals]) -->
	get_pre_branch_info(PreInfo),
	traverse_goal_2(Goal0, Goal),
	get_post_branch_info(PostInfo0),
	traverse_disj_2(PreInfo, Goals0, Goals, PostInfo0, PostInfo),
	set_post_branch_info(PostInfo).

:- pred traverse_disj_2(pre_branch_info::in, hlds_goals::in, hlds_goals::out,
	post_branch_info::in, post_branch_info::out,
	higher_order_info::in, higher_order_info::out) is det.

traverse_disj_2(_, [], [], PostInfo, PostInfo) --> [].
traverse_disj_2(PreInfo, [Goal0 | Goals0], [Goal | Goals],
		PostInfo0, PostInfo) -->
	set_pre_branch_info(PreInfo),
	traverse_goal_2(Goal0, Goal),
	get_post_branch_info(PostInfo1),
	{ merge_post_branch_infos(PostInfo0, PostInfo1, PostInfo2) },
	traverse_disj_2(PreInfo, Goals0, Goals,
		PostInfo2, PostInfo).

		% Switches are treated in exactly the same way as disjunctions.
:- pred traverse_cases(list(case)::in, list(case)::out, 
	higher_order_info::in, higher_order_info::out) is det.

traverse_cases([], []) --> [].
traverse_cases([case(ConsId, Goal0) | Cases0],
		[case(ConsId, Goal) | Cases]) -->
	get_pre_branch_info(PreInfo),
	traverse_goal_2(Goal0, Goal),
	get_post_branch_info(PostInfo0),
	traverse_cases_2(PreInfo, Cases0, Cases, PostInfo0, PostInfo),
	set_post_branch_info(PostInfo).

:- pred traverse_cases_2(pre_branch_info::in, list(case)::in, list(case)::out,
	post_branch_info::in, post_branch_info::out,
	higher_order_info::in, higher_order_info::out) is det.

traverse_cases_2(_, [], [], PostInfo, PostInfo) --> [].
traverse_cases_2(PreInfo, [Case0 | Cases0], [Case | Cases],
		PostInfo0, PostInfo) -->
	set_pre_branch_info(PreInfo),
	{ Case0 = case(ConsId, Goal0) },
	traverse_goal_2(Goal0, Goal),
	{ Case = case(ConsId, Goal) },
	get_post_branch_info(PostInfo1),
	{ merge_post_branch_infos(PostInfo0, PostInfo1, PostInfo2) },
	traverse_cases_2(PreInfo, Cases0, Cases, PostInfo2, PostInfo).

:- type pre_branch_info == pred_vars.
:- type post_branch_info == pred_vars.

:- pred get_pre_branch_info(pre_branch_info::out,
		higher_order_info::in, higher_order_info::out) is det.

get_pre_branch_info(PreInfo, Info0, Info) :-
	get_pred_vars(PreInfo, Info0, Info).

:- pred set_pre_branch_info(pre_branch_info::in,
		higher_order_info::in, higher_order_info::out) is det.

set_pre_branch_info(PreInfo, Info0, Info) :-
	set_pred_vars(PreInfo, Info0, Info).

:- pred get_post_branch_info(pre_branch_info::out,
		higher_order_info::in, higher_order_info::out) is det.

get_post_branch_info(PostInfo, Info0, Info) :-
	get_pred_vars(PostInfo, Info0, Info).

:- pred set_post_branch_info(post_branch_info::in,
		higher_order_info::in, higher_order_info::out) is det.

set_post_branch_info(PostInfo, Info0, Info) :-
	set_pred_vars(PostInfo, Info0, Info).

:- pred get_pred_vars(pred_vars::out,
		higher_order_info::in, higher_order_info::out) is det.

get_pred_vars(PredVars, Info, Info) :-
	Info = info(PredVars, _, _, _, _, _, _, _, _).

:- pred set_pred_vars(pred_vars::in,
		higher_order_info::in, higher_order_info::out) is det.

set_pred_vars(PredVars, Info0, Info) :-
	Info0 = info(_, B, C, D, E, F, G, H, I),
	Info = info(PredVars, B, C, D, E, F, G, H, I).

	% This is used in traversing disjunctions. We save the initial
	% accumulator, then traverse each disjunct starting with the initial
	% info. We then merge the resulting infos.
:- pred merge_post_branch_infos(post_branch_info::in, post_branch_info::in,
					post_branch_info::out) is det.

merge_post_branch_infos(PredVars1, PredVars2, PredVars) :-
	map__to_assoc_list(PredVars1, PredVarList1),
	map__to_assoc_list(PredVars2, PredVarList2),
	merge_pred_var_lists(PredVarList1, PredVarList2, PredVarList),
	map__from_assoc_list(PredVarList, PredVars). 
	
		% find out which variables after a disjunction cannot
		% be specialized
:- pred merge_pred_var_lists(assoc_list(prog_var, maybe_const)::in,  	
			assoc_list(prog_var, maybe_const)::in,
			assoc_list(prog_var, maybe_const)::out) is det.

merge_pred_var_lists([], List, List).
merge_pred_var_lists([PredVar | PredVars], List2, MergedList) :-
	merge_pred_var_with_list(PredVar, List2, MergedList1),
	merge_pred_var_lists(PredVars, MergedList1, MergedList).

:- pred merge_pred_var_with_list(pair(prog_var, maybe_const)::in,
			assoc_list(prog_var, maybe_const)::in,
			assoc_list(prog_var, maybe_const)::out) is det.

merge_pred_var_with_list(VarValue, [], [VarValue]).
merge_pred_var_with_list(Var1 - Value1, [Var2 - Value2 | Vars], MergedList) :-
	(
		Var1 = Var2
	->
		(	(
				Value1 \= Value2
			;	Value1 = multiple_values
			;	Value2 = multiple_values
			)
		->
			MergedList = [Var1 - multiple_values | Vars]
		;
			MergedList = [Var2 - Value2 | Vars]
		)
			% each var occurs at most once most in each list
			% so if we have seen it we don't need to go on
	;
		MergedList = [Var2 - Value2 | MergedList1],
		merge_pred_var_with_list(Var1 - Value1, Vars, MergedList1)
	).	
			
:- pred check_unify(unification::in, higher_order_info::in,
				higher_order_info::out) is det.

	% testing two higher order terms for equality is not allowed
check_unify(simple_test(_, _)) --> [].

check_unify(assign(Var1, Var2)) -->
	maybe_add_alias(Var1, Var2).

	% deconstructing a higher order term is not allowed
check_unify(deconstruct(_, _, _, _, _)) --> [].
	
check_unify(construct(LVar, ConsId, Args, _Modes, _, _, _), Info0, Info) :- 
	Info0 = info(PredVars0, Requests, NewPreds, PredProcId,
		PredInfo, ProcInfo, ModuleInfo, Params, Changed),
	( is_interesting_cons_id(Params, ConsId) ->
		( map__search(PredVars0, LVar, Specializable) ->
			(
				% we can't specialize calls involving
				% a variable with more than one
				% possible value
				Specializable = constant(_, _),
				map__det_update(PredVars0, LVar,
					multiple_values, PredVars)
			;
				% if a variable is already
				% non-specializable, it can't become
				% specializable
				Specializable = multiple_values,
				PredVars = PredVars0
			)
		;
			map__det_insert(PredVars0, LVar,
				constant(ConsId, Args), PredVars)
		)
	;
		PredVars = PredVars0	
	),
	Info = info(PredVars, Requests, NewPreds, PredProcId, 
		PredInfo, ProcInfo, ModuleInfo, Params, Changed).
	
check_unify(complicated_unify(_, _, _)) -->
	{ error("higher_order:check_unify - complicated unification") }.

:- pred is_interesting_cons_id(ho_params::in, cons_id::in) is semidet.

is_interesting_cons_id(ho_params(_, _, yes, _, _),
		cons(qualified(Module, Name), _)) :-
	mercury_private_builtin_module(Module),
	( Name = "type_info"
	; Name = "typeclass_info"
	).
is_interesting_cons_id(ho_params(yes, _, _, _, _), pred_const(_, _, _)).
is_interesting_cons_id(ho_params(_, _, yes, _, _),
		type_ctor_info_const(_, _, _)).
is_interesting_cons_id(ho_params(_, _, yes, _, _),
		base_typeclass_info_const(_, _, _, _)).
	% We need to keep track of int_consts so we can interpret
	% superclass_info_from_typeclass_info and typeinfo_from_typeclass_info.
	% We don't specialize based on them.
is_interesting_cons_id(ho_params(_, _, yes, _, _), int_const(_)).

	% Process a higher-order call or class_method_call to see if it
	% could possibly be specialized.
:- pred maybe_specialize_higher_order_call(prog_var::in, maybe(int)::in,
	list(prog_var)::in, hlds_goal::in, list(hlds_goal)::out, 
	higher_order_info::in, higher_order_info::out) is det.

maybe_specialize_higher_order_call(PredVar, MaybeMethod, Args,
		Goal0 - GoalInfo, Goals, Info0, Info) :-
	Info0 = info(PredVars, Requests0, NewPreds, PredProcId,
		CallerPredInfo0, CallerProcInfo0, ModuleInfo, Params, Changed),
		
	% We can specialize calls to call/N and class_method_call/N if
	% the closure or typeclass_info has a known value.
	(
		map__search(PredVars, PredVar, constant(ConsId, CurriedArgs)),
		(
			ConsId = pred_const(PredId0, ProcId0, _),
			MaybeMethod = no
		->
			PredId = PredId0,
			ProcId = ProcId0,
			list__append(CurriedArgs, Args, AllArgs)
		;
			% A typeclass_info variable should consist of
			% a known base_typeclass_info and some argument
			% typeclass_infos.
			ConsId = cons(TypeClassInfo, _),
			mercury_private_builtin_module(Module),
			TypeClassInfo = qualified(Module, "typeclass_info"),
			CurriedArgs = [BaseTypeClassInfo | OtherTypeClassArgs],
			map__search(PredVars, BaseTypeClassInfo,
				constant(BaseConsId, _)),
			BaseConsId = base_typeclass_info_const(_,
				ClassId, Instance, _),
			MaybeMethod = yes(Method),
			module_info_instances(ModuleInfo, Instances),
			map__lookup(Instances, ClassId, InstanceList),
			list__index1_det(InstanceList, Instance, InstanceDefn),
			InstanceDefn = hlds_instance_defn(_, _,
				InstanceConstraints, _, _,
				yes(ClassInterface), _, _),
			list__length(InstanceConstraints, InstanceArity),
			list__take(InstanceArity, OtherTypeClassArgs,
				InstanceConstraintArgs)
		->	
			list__index1_det(ClassInterface, Method,
				hlds_class_proc(PredId, ProcId)),
			list__append(InstanceConstraintArgs, Args, AllArgs)
		;
			fail
		)
	->
		construct_specialized_higher_order_call(ModuleInfo,
			PredId, ProcId, AllArgs, GoalInfo, Goal, Info0, Info),
		Goals = [Goal]
	;
		% Handle a class method call where we know which instance
		% is being used, but we haven't seen a construction for
		% the typeclass_info. This can happen for user-guided
		% typeclass specialization, because the type-specialized class
		% constraint is still in the constraint list, so a
		% typeclass_info is passed in by the caller rather than
		% being constructed locally.
		%
		% The problem is that in importing modules we don't know
		% which instance declarations are visible in the imported
		% module, so we don't know which class constraints are
		% redundant after type specialization.
		MaybeMethod = yes(Method),

		proc_info_vartypes(CallerProcInfo0, VarTypes),
		map__lookup(VarTypes, PredVar, TypeClassInfoType),
		polymorphism__typeclass_info_class_constraint(
			TypeClassInfoType, ClassConstraint),
		ClassConstraint = constraint(ClassName, ClassArgs),
		list__length(ClassArgs, ClassArity),
		module_info_instances(ModuleInfo, InstanceTable),
        	map__lookup(InstanceTable, class_id(ClassName, ClassArity),
			Instances),
		pred_info_typevarset(CallerPredInfo0, TVarSet0),
		find_matching_instance_method(Instances, Method,
			ClassArgs, PredId, ProcId, InstanceConstraints,
			TVarSet0, TVarSet)
	->
		pred_info_set_typevarset(CallerPredInfo0,
			TVarSet, CallerPredInfo),
		% Pull out the argument typeclass_infos. 
		( InstanceConstraints = [] ->
			ExtraGoals = [],
			CallerProcInfo = CallerProcInfo0,
			AllArgs = Args
		;
			mercury_private_builtin_module(PrivateBuiltin),
			module_info_get_predicate_table(ModuleInfo, PredTable),
			ExtractArgSymName = qualified(PrivateBuiltin,
				"instance_constraint_from_typeclass_info"),
			(
				predicate_table_search_pred_sym_arity(
					PredTable, ExtractArgSymName,
					3, [ExtractArgPredId0])
			->
				ExtractArgPredId = ExtractArgPredId0
			;
				error(
	"higher_order.m: can't find `instance_constraint_from_typeclass_info'")
			),
			hlds_pred__initial_proc_id(ExtractArgProcId),
			get_arg_typeclass_infos(PredVar, ExtractArgPredId,
				ExtractArgProcId, ExtractArgSymName,
				InstanceConstraints, 1,
				ExtraGoals, ArgTypeClassInfos,
				CallerProcInfo0, CallerProcInfo),
			list__append(ArgTypeClassInfos, Args, AllArgs)
		),
		Info1 = info(PredVars, Requests0, NewPreds, PredProcId,
			CallerPredInfo, CallerProcInfo, ModuleInfo,
			Params, Changed),
		construct_specialized_higher_order_call(ModuleInfo,
			PredId, ProcId, AllArgs, GoalInfo, Goal, Info1, Info),
		list__append(ExtraGoals, [Goal], Goals)
	;
		% non-specializable call/N or class_method_call/N
		Goals = [Goal0 - GoalInfo],
		Info = Info0
	).

:- pred find_matching_instance_method(list(hlds_instance_defn)::in, int::in,
	list(type)::in, pred_id::out, proc_id::out,
	list(class_constraint)::out, tvarset::in, tvarset::out) is semidet.

find_matching_instance_method([Instance | Instances], MethodNum,
		ClassTypes, PredId, ProcId, Constraints, TVarSet0, TVarSet) :-
        (
		instance_matches(ClassTypes, Instance,
			Constraints0, TVarSet0, TVarSet1)
	->
		TVarSet = TVarSet1,
		Constraints = Constraints0,
		Instance = hlds_instance_defn(_, _, _,
			_, _, yes(ClassInterface), _, _),
		list__index1_det(ClassInterface, MethodNum,
			hlds_class_proc(PredId, ProcId))
	;
		find_matching_instance_method(Instances, MethodNum,
			ClassTypes, PredId, ProcId, Constraints,
			TVarSet0, TVarSet)
	).

:- pred instance_matches(list(type)::in, hlds_instance_defn::in,
	list(class_constraint)::out, tvarset::in, tvarset::out) is semidet.
	
instance_matches(ClassTypes, Instance, Constraints, TVarSet0, TVarSet) :-
	Instance = hlds_instance_defn(_, _, Constraints0,
		InstanceTypes0, _, _, InstanceTVarSet, _),
	varset__merge_subst(TVarSet0, InstanceTVarSet, TVarSet,
		RenameSubst),
	term__apply_substitution_to_list(InstanceTypes0,
		RenameSubst, InstanceTypes),
	type_list_subsumes(InstanceTypes, ClassTypes, Subst),
	apply_subst_to_constraint_list(RenameSubst,
		Constraints0, Constraints1),
	apply_rec_subst_to_constraint_list(Subst,
		Constraints1, Constraints).

	% Build calls to
	% `private_builtin:instance_constraint_from_typeclass_info/3'
	% to extract the typeclass_infos for the constraints on an instance.
	% This simulates the action of `do_call_class_method' in
	% runtime/mercury_ho_call.c.
:- pred get_arg_typeclass_infos(prog_var::in, pred_id::in, proc_id::in,
		sym_name::in, list(class_constraint)::in, int::in,
		list(hlds_goal)::out, list(prog_var)::out,
		proc_info::in, proc_info::out) is det.

get_arg_typeclass_infos(_, _, _, _, [], _, [], [], ProcInfo, ProcInfo).
get_arg_typeclass_infos(TypeClassInfoVar, PredId, ProcId, SymName,
		[InstanceConstraint | InstanceConstraints],
		ConstraintNum, [ConstraintNumGoal, CallGoal | Goals],
		[ArgTypeClassInfoVar | Vars], ProcInfo0, ProcInfo) :-
	polymorphism__build_typeclass_info_type(InstanceConstraint,
		ArgTypeClassInfoType),
	proc_info_create_var_from_type(ProcInfo0, ArgTypeClassInfoType,
		ArgTypeClassInfoVar, ProcInfo1),
	MaybeContext = no,
	make_int_const_construction(ConstraintNum, ConstraintNumGoal,
		ConstraintNumVar, ProcInfo1, ProcInfo2),
	Args = [TypeClassInfoVar, ConstraintNumVar, ArgTypeClassInfoVar],

	set__list_to_set(Args, NonLocals),
	instmap_delta_init_reachable(InstMapDelta0),
	instmap_delta_insert(InstMapDelta0, ArgTypeClassInfoVar,
		ground(shared, no), InstMapDelta),
	goal_info_init(NonLocals, InstMapDelta, det, GoalInfo),
	CallGoal = call(PredId, ProcId, Args, not_builtin,
		MaybeContext, SymName) - GoalInfo,
	get_arg_typeclass_infos(TypeClassInfoVar, PredId, ProcId, SymName,
		InstanceConstraints, ConstraintNum + 1, Goals,
		Vars, ProcInfo2, ProcInfo).

:- pred construct_specialized_higher_order_call(module_info::in,
	pred_id::in, proc_id::in, list(prog_var)::in, hlds_goal_info::in,
	hlds_goal::out, higher_order_info::in, higher_order_info::out) is det.

construct_specialized_higher_order_call(ModuleInfo, PredId, ProcId,
		AllArgs, GoalInfo, Goal - GoalInfo, Info0, Info) :-
	module_info_pred_info(ModuleInfo, PredId, PredInfo),
	pred_info_module(PredInfo, ModuleName),
	pred_info_name(PredInfo, PredName),
	SymName = qualified(ModuleName, PredName),
	code_util__builtin_state(ModuleInfo, PredId, ProcId, Builtin),

	MaybeContext = no,
	Goal1 = call(PredId, ProcId, AllArgs, Builtin, MaybeContext, SymName),
	higher_order_info_update_changed_status(changed, Info0, Info1),
	maybe_specialize_call(Goal1 - GoalInfo, Goal - _, Info1, Info).

		% Process a call to see if it could possibly be specialized.
:- pred maybe_specialize_call(hlds_goal::in, hlds_goal::out,
		higher_order_info::in, higher_order_info::out) is det.

maybe_specialize_call(Goal0 - GoalInfo, Goal - GoalInfo, Info0, Info) :-
	Info0 = info(PredVars, Requests0, NewPreds, PredProcId,
			PredInfo0, ProcInfo0, Module0, Params, Changed0),
	(
		Goal0 = call(_, _, _, _, _, _)
	->
		Goal0 = call(CalledPred, CalledProc, Args0, IsBuiltin,
					MaybeContext, _SymName0)
	;
		error("higher_order.m: call expected")
	),
	module_info_pred_info(Module0, CalledPred, CalleePredInfo),
	(
		% Look for calls to unify/2 and compare/3 which can
		% be specialized.
		specialize_special_pred(CalledPred, CalledProc,
			Args0, MaybeContext, Goal1, Info0, Info1) 
	->
		Goal = Goal1,
		higher_order_info_update_changed_status(changed, Info1, Info)
	;
		polymorphism__is_typeclass_info_manipulator(Module0,
			CalledPred, Manipulator)
	->
		interpret_typeclass_info_manipulator(Manipulator, Args0,
			Goal0, Goal, Info0, Info)
	;
		(
			pred_info_is_imported(CalleePredInfo),
			module_info_type_spec_info(Module0,
				type_spec_info(TypeSpecProcs, _, _, _)),
			\+ set__member(proc(CalledPred, CalledProc),
				TypeSpecProcs)
		;
			pred_info_is_pseudo_imported(CalleePredInfo),
			hlds_pred__in_in_unification_proc_id(CalledProc)
		;
			pred_info_get_goal_type(CalleePredInfo, pragmas)
		)
	->
		Info = Info0,
		Goal = Goal0
	;
		pred_info_arg_types(CalleePredInfo, CalleeArgTypes),
		pred_info_import_status(CalleePredInfo, CalleeStatus),
		proc_info_vartypes(ProcInfo0, VarTypes),
		find_higher_order_args(Module0, CalleeStatus, Args0,
			CalleeArgTypes, VarTypes, PredVars, 1, [],
			HigherOrderArgs0),

		PredProcId = proc(CallerPredId, _),
		module_info_type_spec_info(Module0,
			type_spec_info(_, ForceVersions, _, _)),
		( set__member(CallerPredId, ForceVersions) ->
			IsUserSpecProc = yes
		;
			IsUserSpecProc = no
		),

		( 
			(
				HigherOrderArgs0 = [_ | _]
			;
				% We should create these
				% even if there is no specialization
				% to avoid link errors.
				IsUserSpecProc = yes
			;
				Params = ho_params(_, _, UserTypeSpec, _, _),
				UserTypeSpec = yes,
				map__apply_to_list(Args0, VarTypes, ArgTypes),

				% Check whether any typeclass constraints
				% now match an instance.
				pred_info_get_class_context(CalleePredInfo,
					CalleeClassContext),
				CalleeClassContext =
					constraints(CalleeUnivConstraints0, _),
				pred_info_typevarset(CalleePredInfo,
					CalleeTVarSet),
				pred_info_get_exist_quant_tvars(CalleePredInfo,
					CalleeExistQTVars),	
				pred_info_typevarset(PredInfo0, TVarSet),
				type_subst_makes_instance_known(
					Module0, CalleeUnivConstraints0,
					TVarSet, ArgTypes, CalleeTVarSet,
					CalleeExistQTVars, CalleeArgTypes)
			)
		->
			list__reverse(HigherOrderArgs0, HigherOrderArgs),
			goal_info_get_context(GoalInfo, Context),
			find_matching_version(Info0, CalledPred, CalledProc,
				Args0, Context, HigherOrderArgs,
				IsUserSpecProc, FindResult),
			(
				FindResult = match(match(Match, _, Args1,
						ExtraTypeInfoTypes)),
				Match = new_pred(NewPredProcId, _, _,
					NewName, _HOArgs, _, _, _, _, _, _),
				NewPredProcId = proc(NewCalledPred,
					NewCalledProc),

				construct_extra_type_infos(
					ExtraTypeInfoTypes, ExtraTypeInfoVars,
					ExtraTypeInfoGoals,
					Module0, Module, PredInfo0, PredInfo,
					ProcInfo0, ProcInfo),

				list__append(ExtraTypeInfoVars, Args1, Args),	
				CallGoal = call(NewCalledPred, NewCalledProc,
					Args, IsBuiltin, MaybeContext, NewName),
				list__append(ExtraTypeInfoGoals,
					[CallGoal - GoalInfo], GoalList),
				Goal = conj(GoalList),
				update_changed_status(Changed0,
					changed, Changed),
				Requests = Requests0
			;
				% There is a known higher order variable in
				% the call, so we put in a request for a
				% specialized version of the pred.
				FindResult = request(Request),
				Goal = Goal0,
				set__insert(Requests0, Request, Requests),
				update_changed_status(Changed0,
					request, Changed),
				Module = Module0,
				PredInfo = PredInfo0,
				ProcInfo = ProcInfo0
			;
				FindResult = no_request,
				Goal = Goal0,
				Requests = Requests0,
				Changed = Changed0,
				Module = Module0,
				PredInfo = PredInfo0,
				ProcInfo = ProcInfo0
			),
			Info = info(PredVars, Requests, NewPreds, PredProcId,
				PredInfo, ProcInfo, Module, Params, Changed)
		;
			Info = Info0,
			Goal = Goal0
		)	
	).

	% Returns a list of the higher-order arguments in a call that have
	% a known value.
:- pred find_higher_order_args(module_info::in, import_status::in,
	list(prog_var)::in, list(type)::in, map(prog_var, type)::in,
	pred_vars::in, int::in, list(higher_order_arg)::in,
	list(higher_order_arg)::out) is det.

find_higher_order_args(_, _, [], _, _, _, _, HOArgs, HOArgs).
find_higher_order_args(_, _, [_|_], [], _, _, _, _, _) :-
	error("find_higher_order_args: length mismatch").
find_higher_order_args(ModuleInfo, CalleeStatus, [Arg | Args],
		[CalleeArgType | CalleeArgTypes], VarTypes,
		PredVars, ArgNo, HOArgs0, HOArgs) :-
	NextArg is ArgNo + 1,
	(
		% We don't specialize arguments whose declared type is
		% polymorphic. The closure they pass cannot possibly
		% be called within the called predicate, since that predicate 
		% doesn't know it's a closure (without some dodgy use of
		% type_to_univ and univ_to_type).
		map__search(PredVars, Arg, constant(ConsId, CurriedArgs)),

		% We don't specialize based on int_consts (we only keep track
		% of them to interpret calls to the procedures which
		% extract fields from typeclass_infos).
		ConsId \= int_const(_),

		( ConsId = pred_const(_, _, _) ->
			% If we don't have clauses for the callee, we can't
			% specialize any higher-order arguments. We may be
			% able to do user guided type specialization.
			CalleeStatus \= imported(_),
			type_is_higher_order(CalleeArgType, _, _, _)
		;
			true
		)
	->
		% Find any known higher-order arguments
		% in the list of curried arguments.
		map__apply_to_list(CurriedArgs, VarTypes, CurriedArgTypes),
		( ConsId = pred_const(PredId, _, _) ->
			module_info_pred_info(ModuleInfo, PredId, PredInfo),
			pred_info_arg_types(PredInfo, CurriedCalleeArgTypes)
		;
			CurriedCalleeArgTypes = CurriedArgTypes
		),
		find_higher_order_args(ModuleInfo, CalleeStatus, CurriedArgs,
			CurriedCalleeArgTypes, VarTypes,
			PredVars, 1, [], HOCurriedArgs0),
		list__reverse(HOCurriedArgs0, HOCurriedArgs),
		list__length(CurriedArgs, NumArgs),
		HOArg = higher_order_arg(ConsId, ArgNo, NumArgs,
			CurriedArgs, CurriedArgTypes, HOCurriedArgs),
		HOArgs1 = [HOArg | HOArgs0]
	;
		HOArgs1 = HOArgs0
	),
	find_higher_order_args(ModuleInfo, CalleeStatus, Args, CalleeArgTypes,
		VarTypes, PredVars, NextArg, HOArgs1, HOArgs).

	% Succeeds if the type substitution for a call makes any of
	% the class constraints match an instance which was not matched
	% before.
:- pred type_subst_makes_instance_known(module_info::in,
		list(class_constraint)::in, tvarset::in, list(type)::in,
		tvarset::in, existq_tvars::in, list(type)::in) is semidet.

type_subst_makes_instance_known(ModuleInfo, CalleeUnivConstraints0, TVarSet0,
		ArgTypes, CalleeTVarSet, CalleeExistQVars, CalleeArgTypes0) :-
	CalleeUnivConstraints0 \= [],
	varset__merge_subst(TVarSet0, CalleeTVarSet,
		TVarSet, TypeRenaming),
	term__apply_substitution_to_list(CalleeArgTypes0, TypeRenaming,
		CalleeArgTypes1),

	% Substitute the types in the callee's class constraints. 
	% Typechecking has already succeeded, so none of the head type
	% variables will be bound by the substitution.
	HeadTypeParams = [],
	inlining__get_type_substitution(CalleeArgTypes1, ArgTypes,
		HeadTypeParams, CalleeExistQVars, TypeSubn),
	apply_subst_to_constraint_list(TypeRenaming,
		CalleeUnivConstraints0, CalleeUnivConstraints1),
	apply_rec_subst_to_constraint_list(TypeSubn,
		CalleeUnivConstraints1, CalleeUnivConstraints),
	assoc_list__from_corresponding_lists(CalleeUnivConstraints0,
		CalleeUnivConstraints, CalleeUnivConstraintAL),

	% Go through each constraint in turn, checking whether any instances
	% match which didn't before the substitution was applied.
	list__member(CalleeUnivConstraint0 - CalleeUnivConstraint,
		CalleeUnivConstraintAL),
	CalleeUnivConstraint0 = constraint(ClassName, ConstraintArgs0),
	list__length(ConstraintArgs0, ClassArity),
	CalleeUnivConstraint = constraint(_, ConstraintArgs),
	module_info_instances(ModuleInfo, InstanceTable),
	map__search(InstanceTable, class_id(ClassName, ClassArity), Instances),
	list__member(Instance, Instances), 	
	instance_matches(ConstraintArgs, Instance, _, TVarSet, _),
	\+ instance_matches(ConstraintArgs0, Instance, _, TVarSet, _).

:- type find_result
	--->	match(match)
	; 	request(request)
	;	no_request
	.

:- type match
	---> match(
		new_pred,
		maybe(int),	% was the match partial, if so,
				% how many higher_order arguments
				% matched.
		list(prog_var),	% the arguments to the specialised call.
		list(type)	% type variables for which extra type-infos
				% must be added to the start of the argument
				% list.
	).

	% WARNING - do not filter out higher-order arguments from the
	% request returned by find_matching_version, otherwise some
	% type-infos that the call specialization code is expecting to
	% come from the curried arguments of the higher-order arguments
	% will not be present in the specialized argument list.
:- pred find_matching_version(higher_order_info::in, 
	pred_id::in, proc_id::in, list(prog_var)::in, prog_context::in,
	list(higher_order_arg)::in, bool::in, find_result::out) is det.

	% Args0 is the original list of arguments.
	% Args is the original list of arguments with the curried arguments
	% of known higher-order arguments added.
find_matching_version(Info, CalledPred, CalledProc, Args0, Context,
		HigherOrderArgs, IsUserSpecProc, Result) :-
	Info = info(_, _, NewPreds, Caller,
		PredInfo, ProcInfo, ModuleInfo, Params, _),

	% WARNING - do not filter out higher-order arguments after this step,
	% except when partially matching against a previously produced
	% specialization, otherwise some type-infos that the call
	% specialization code is expecting to come from the curried
	% arguments of the higher-order arguments will not be present
	% in the specialized argument list.
	module_info_pred_info(ModuleInfo, CalledPred, CalledPredInfo),
	module_info_globals(ModuleInfo, Globals),
	proc_interface_should_use_typeinfo_liveness(CalledPredInfo,
		CalledProc, Globals, TypeInfoLiveness),
	get_extra_arguments(HigherOrderArgs, Args0, Args),
	compute_extra_typeinfos(TypeInfoLiveness,
		Info, Args, ExtraTypeInfoTVars),

	proc_info_vartypes(ProcInfo, VarTypes),
	map__apply_to_list(Args0, VarTypes, CallArgTypes),
	pred_info_typevarset(PredInfo, TVarSet),

	Request = request(Caller, proc(CalledPred, CalledProc), Args0,
		ExtraTypeInfoTVars, HigherOrderArgs, CallArgTypes,
		TypeInfoLiveness, TVarSet, IsUserSpecProc, Context), 

	% Check to see if any of the specialized
	% versions of the called pred apply here.
	( 
		NewPreds = new_preds(NewPredMap, _),
		map__search(NewPredMap, proc(CalledPred, CalledProc),
			Versions0),
		set__to_sorted_list(Versions0, Versions),
		search_for_version(Info, Params, ModuleInfo, Request,
			Versions, no, Match)
	->
		Result = match(Match)
	;
		Params = ho_params(HigherOrder, TypeSpec, UserTypeSpec, _, _),
		(
			UserTypeSpec = yes,
			IsUserSpecProc = yes
		;
			module_info_pred_info(ModuleInfo,
				CalledPred, CalledPredInfo),
			\+ pred_info_is_imported(CalledPredInfo),
			(
				% This handles the predicates introduced
				% by check_typeclass.m to call the class
				% methods for a specific instance.
				% Without this, user-specified specialized
				% versions of class methods won't be called.
				UserTypeSpec = yes,
				pred_info_get_markers(CalledPredInfo,
					Markers),
				(
					check_marker(Markers, class_method)
				;
					check_marker(Markers,
						class_instance_method)
				)
			;
				HigherOrder = yes,
				list__member(HOArg, HigherOrderArgs),
				HOArg = higher_order_arg(pred_const(_, _, _),
					_, _, _, _, _)
			;
				TypeSpec = yes
			)
		)
	->
		Result = request(Request)
	;
		Result = no_request
	).

	% If `--typeinfo-liveness' is set, specializing type `T' to `list(U)'
	% requires passing in the type-info for `U'. This predicate
	% works out which extra variables to pass in given the argument
	% list for the call.
:- pred compute_extra_typeinfos(bool::in, higher_order_info::in,
		list(prog_var)::in, list(tvar)::out) is det.

compute_extra_typeinfos(TypeInfoLiveness, Info, Args1, ExtraTypeInfoTVars) :-
	( TypeInfoLiveness = yes ->
		% Work out which type variables don't already have type-infos
		% in the list of argument types.
		% The list is in the order which the type variables occur
		% in the list of argument types so that the extra type-info
		% arguments for calls to imported user-guided type
		% specialization procedures can be matched against the
		% specialized version (`goal_util__extra_nonlocal_typeinfos'
		% is not used here because the type variables are returned
		% sorted by variable number, which will vary between calls).
		Info = info(_, _, _, _, _, ProcInfo, _, _, _),
		proc_info_vartypes(ProcInfo, VarTypes),
		map__apply_to_list(Args1, VarTypes, ArgTypes),
		term__vars_list(ArgTypes, AllTVars),
		( AllTVars = [] ->
			ExtraTypeInfoTVars = []
		;
			list__foldl(arg_type_contains_type_info_for_tvar,
				ArgTypes, [], TypeInfoTVars),
			list__delete_elems(AllTVars, TypeInfoTVars,
				ExtraTypeInfoTVars0),
			list__remove_dups(ExtraTypeInfoTVars0,
				ExtraTypeInfoTVars)
		)
	;
		ExtraTypeInfoTVars = []
	).

:- pred arg_type_contains_type_info_for_tvar((type)::in, list(tvar)::in,
		list(tvar)::out) is det.

arg_type_contains_type_info_for_tvar(TypeInfoType, TVars0, TVars) :-
	(
		polymorphism__type_info_type(TypeInfoType, Type),
		Type = term__variable(TVar)
	->
		TVars = [TVar | TVars0]
	;
		polymorphism__typeclass_info_class_constraint(TypeInfoType,
			Constraint),
		Constraint = constraint(_ClassName, ClassArgTypes)
	->
		% Find out which tvars the typeclass-info contains
		% the type-infos for.
		list__filter_map(
			(pred(ClassArgType::in, ClassTVar::out) is semidet :-
				ClassArgType = term__variable(ClassTVar)
			), ClassArgTypes, ClassTVars),
		list__append(ClassTVars, TVars0, TVars)
	;
		TVars = TVars0
	).

:- pred construct_extra_type_infos(list(type)::in,
		list(prog_var)::out, list(hlds_goal)::out,
		module_info::in, module_info::out,
		pred_info::in, pred_info::out,
		proc_info::in, proc_info::out) is det.

construct_extra_type_infos(Types, TypeInfoVars, TypeInfoGoals,
		ModuleInfo0, ModuleInfo, PredInfo0, PredInfo,
		ProcInfo0, ProcInfo) :-
	create_poly_info(ModuleInfo0, PredInfo0, ProcInfo0, PolyInfo0),
	term__context_init(Context),
	polymorphism__make_type_info_vars(Types, Context,
		TypeInfoVars, TypeInfoGoals, PolyInfo0, PolyInfo),
	poly_info_extract(PolyInfo, PredInfo0, PredInfo,
		ProcInfo0, ProcInfo, ModuleInfo).

:- pred search_for_version(higher_order_info::in, ho_params::in,
		module_info::in, request::in, list(new_pred)::in,
		maybe(match)::in, match::out) is semidet.

search_for_version(_Info, _Params, _ModuleInfo, _Request,
		[], yes(Match), Match).
search_for_version(Info, Params, ModuleInfo, Request,
		[Version | Versions], Match0, Match) :-
	(
		version_matches(Params, ModuleInfo, Request, Version, Match1)
	->
		(
			Match1 = match(_, MatchIsPartial, _, _),
			MatchIsPartial = no
		->
			Match = Match1
		;
			(
				Match0 = no
			->
				Match2 = yes(Match1)
			;
				% pick the best match
				Match0 = yes(match(_, yes(NumMatches0), _, _)),
				Match1 = match(_, yes(NumMatches1), _, _)
			->
				( NumMatches0 > NumMatches1 ->
					Match2 = Match0
				;
					Match2 = yes(Match1)
				)
			;
				error("higher_order: search_for_version")
			),
			search_for_version(Info, Params, ModuleInfo, Request,
				Versions, Match2, Match)
		)
	;
		search_for_version(Info, Params, ModuleInfo, Request,
			Versions, Match0, Match)
	).

	% Check whether the request has already been implemented by 
	% the new_pred, maybe ordering the list of extra type_infos
	% in the caller predicate to match up with those in the caller.
:- pred version_matches(ho_params::in, module_info::in, request::in,
		new_pred::in, match::out) is semidet.

version_matches(Params, ModuleInfo, Request, Version,
		match(Version, PartialMatch, Args, ExtraTypeInfoTypes)) :-

	Request = request(_, Callee, Args0, _, RequestHigherOrderArgs,
		CallArgTypes, _, RequestTVarSet, _, _), 
	Version = new_pred(_, _, _, _, VersionHigherOrderArgs,
		_, VersionExtraTypeInfoTVars, VersionArgTypes0,
		_, VersionTVarSet, _),

	higher_order_args_match(RequestHigherOrderArgs,
		VersionHigherOrderArgs, HigherOrderArgs, MatchIsPartial),

	( MatchIsPartial = yes ->
		list__length(HigherOrderArgs, NumHOArgs),
		PartialMatch = yes(NumHOArgs)
	;
		PartialMatch = no
	),

	Params = ho_params(_, TypeSpec, _, _, _),

	Callee = proc(CalleePredId, _),
	module_info_pred_info(ModuleInfo, CalleePredId, CalleePredInfo),
	(
		% Don't accept partial matches unless the predicate is
		% imported or we are only doing user-guided type
		% specialization.
		MatchIsPartial = no
	;
		TypeSpec = no	
	;	
		pred_info_is_imported(CalleePredInfo)
	),

	% Rename apart type variables.
	varset__merge_subst(RequestTVarSet, VersionTVarSet, _, TVarSubn),
	term__apply_substitution_to_list(VersionArgTypes0, TVarSubn,
		VersionArgTypes),
	type_list_subsumes(VersionArgTypes, CallArgTypes, TypeSubn),

	% Work out the types of the extra type-info variables that
	% need to be passed to the specialized version.
	term__var_list_to_term_list(VersionExtraTypeInfoTVars,
		VersionExtraTypeInfoTypes),
	term__apply_substitution_to_list(VersionExtraTypeInfoTypes,
		TVarSubn, ExtraTypeInfoTypes0),
	term__apply_rec_substitution_to_list(ExtraTypeInfoTypes0, TypeSubn,
		ExtraTypeInfoTypes),
	
	get_extra_arguments(HigherOrderArgs, Args0, Args).

:- pred higher_order_args_match(list(higher_order_arg)::in,
		list(higher_order_arg)::in, list(higher_order_arg)::out,
		bool::out) is semidet.

higher_order_args_match([], [], [], no).
higher_order_args_match([_ | _], [], [], yes).
higher_order_args_match([RequestArg | Args1], [VersionArg | Args2],
		Args, PartialMatch) :-
	RequestArg = higher_order_arg(ConsId1, ArgNo1, _, _, _, _),
	VersionArg = higher_order_arg(ConsId2, ArgNo2, _, _, _, _),

	( ArgNo1 = ArgNo2 ->
		ConsId1 = ConsId2,
		RequestArg = higher_order_arg(_, _, NumArgs,
			CurriedArgs, CurriedArgTypes, HOCurriedArgs1),
		VersionArg = higher_order_arg(_, _, NumArgs,
			_, _, HOCurriedArgs2),
		higher_order_args_match(HOCurriedArgs1, HOCurriedArgs2,
			NewHOCurriedArgs, PartialMatch),
		higher_order_args_match(Args1, Args2, Args3, _),
		NewRequestArg = higher_order_arg(ConsId1, ArgNo1, NumArgs,
			CurriedArgs, CurriedArgTypes, NewHOCurriedArgs),
		Args = [NewRequestArg | Args3]
	;
		% type-info arguments present in the request may be missing
		% from the version if we are doing user-guided type
		% specialization. 
		% All of the arguments in the version must be
		% present in the request for a match. 
		ArgNo1 < ArgNo2,

		% All the higher-order arguments must be present in the
		% version otherwise we should create a new one.
		ConsId1 \= pred_const(_, _, _),
		PartialMatch = yes,
		higher_order_args_match(Args1, [VersionArg | Args2], Args, _)
	).

	% Add the curried arguments of the higher-order terms to the
	% argument list. The order here must match that generated by
	% construct_higher_order_terms.
:- pred get_extra_arguments(list(higher_order_arg)::in,
		list(prog_var)::in, list(prog_var)::out) is det.

get_extra_arguments([], Args, Args).
get_extra_arguments([HOArg | HOArgs], Args0, Args) :-
	HOArg = higher_order_arg(_, _, _,
		CurriedArgs0, _, HOCurriedArgs),
	get_extra_arguments(HOCurriedArgs, CurriedArgs0, CurriedArgs),
	list__append(Args0, CurriedArgs, Args1),
	get_extra_arguments(HOArgs, Args1, Args).

		% if the right argument of an assignment is a higher order
		% term with a known value, we need to add an entry for
		% the left argument
:- pred maybe_add_alias(prog_var::in, prog_var::in, higher_order_info::in,
				higher_order_info::out) is det.

maybe_add_alias(LVar, RVar,
		info(PredVars0, Requests, NewPreds, PredProcId, 
			PredInfo, ProcInfo, ModuleInfo, Params, Changed),
		info(PredVars, Requests, NewPreds, PredProcId,
			PredInfo, ProcInfo, ModuleInfo, Params, Changed)) :-
	(
		map__search(PredVars0, RVar, constant(A, B))
	->
		map__set(PredVars0, LVar, constant(A, B), PredVars)
	;
		PredVars = PredVars0
	).
		
:- pred update_changed_status(changed::in, changed::in, changed::out) is det.

update_changed_status(changed, _, changed).
update_changed_status(request, changed, changed).
update_changed_status(request, request, request).
update_changed_status(request, unchanged, request).
update_changed_status(unchanged, Changed, Changed).

:- pred higher_order_info_update_changed_status(changed::in,
		higher_order_info::in, higher_order_info::out) is det.

higher_order_info_update_changed_status(Changed1, Info0, Info) :-
	Info0 = info(A,B,C,D,E,F,G,H, Changed0),
	update_changed_status(Changed0, Changed1, Changed),
	Info = info(A,B,C,D,E,F,G,H, Changed).

%-------------------------------------------------------------------------------

	% Interpret a call to `type_info_from_typeclass_info',
	% `superclass_from_typeclass_info' or
	% `instance_constraint_from_typeclass_info'.
	% This should be kept in sync with compiler/polymorphism.m,
	% library/private_builtin.m and runtime/mercury_type_info.h.
:- pred interpret_typeclass_info_manipulator(typeclass_info_manipulator::in,
	list(prog_var)::in, hlds_goal_expr::in, hlds_goal_expr::out,
	higher_order_info::in, higher_order_info::out) is det.

interpret_typeclass_info_manipulator(Manipulator, Args,
		Goal0, Goal, Info0, Info) :-
	Info0 = info(PredVars0, _, _, _, _, _, ModuleInfo, _, _),
	(
		Args = [TypeClassInfoVar, IndexVar, TypeInfoVar],
		map__search(PredVars0, TypeClassInfoVar,
			constant(_TypeClassInfoConsId, TypeClassInfoArgs)),

		map__search(PredVars0, IndexVar,
			constant(int_const(Index0), [])),

		% Extract the number of class constraints on the instance
		% from the base_typeclass_info.
		TypeClassInfoArgs = [BaseTypeClassInfoVar | OtherVars],

		map__search(PredVars0, BaseTypeClassInfoVar,
		    	constant(base_typeclass_info_const(_,
				ClassId, InstanceNum, _), _))
	->
		module_info_instances(ModuleInfo, Instances),
		map__lookup(Instances, ClassId, InstanceDefns),
		list__index1_det(InstanceDefns, InstanceNum, InstanceDefn),
		InstanceDefn = hlds_instance_defn(_, _, Constraints, _,_,_,_,_),
		(
			Manipulator = type_info_from_typeclass_info,
			list__length(Constraints, NumConstraints),	
			Index = Index0 + NumConstraints
		;
			Manipulator = superclass_from_typeclass_info,
			list__length(Constraints, NumConstraints),	
			% polymorphism.m adds the number of
			% type_infos to the index.
			Index = Index0 + NumConstraints
		;
			Manipulator = instance_constraint_from_typeclass_info,
			Index = Index0
		),
		list__index1_det(OtherVars, Index, TypeInfoArg),
		maybe_add_alias(TypeInfoVar, TypeInfoArg, Info0, Info),
		Uni = assign(TypeInfoVar, TypeInfoArg),
		in_mode(In),
		out_mode(Out),
		Goal = unify(TypeInfoVar, var(TypeInfoArg), Out - In,
			Uni, unify_context(explicit, []))
	;
		Goal = Goal0,
		Info = Info0
	).

%-------------------------------------------------------------------------------

	% Succeed if the called pred is "unify", "compare" or "index" and
	% is specializable, returning a specialized goal.
:- pred specialize_special_pred(pred_id::in, proc_id::in, list(prog_var)::in,
		maybe(call_unify_context)::in, hlds_goal_expr::out,
		higher_order_info::in, higher_order_info::out) is semidet.
		
specialize_special_pred(CalledPred, _CalledProc, Args,
		MaybeContext, Goal, Info0, Info) :-
	Info0 = info(PredVars, B, C, D, E, ProcInfo0, ModuleInfo, H, I),
	proc_info_vartypes(ProcInfo0, VarTypes),
	module_info_pred_info(ModuleInfo, CalledPred, CalledPredInfo),
	mercury_public_builtin_module(PublicBuiltin),
	pred_info_module(CalledPredInfo, PublicBuiltin),
	pred_info_name(CalledPredInfo, PredName),
	pred_info_arity(CalledPredInfo, PredArity),
	special_pred_name_arity(SpecialId, PredName, _, PredArity),
	special_pred_get_type(PredName, Args, Var),
	map__lookup(VarTypes, Var, SpecialPredType),
	SpecialPredType \= term__variable(_),
	Args = [TypeInfoVar | SpecialPredArgs],
	map__search(PredVars, TypeInfoVar,
		constant(_TypeInfoConsId, TypeInfoVarArgs)),
	type_to_type_id(SpecialPredType, _ - TypeArity, _),
	( TypeArity = 0 ->
		TypeInfoArgs = []
	;
		TypeInfoVarArgs = [_TypeCtorInfo | TypeInfoArgs]
	),

	(
		SpecialId = unify,
		type_is_atomic(SpecialPredType, ModuleInfo)
	->
		% Unifications of atomic types can be specialized
		% to simple_tests.
		SpecialPredArgs = [Arg1, Arg2],
		in_mode(In),
		Goal = unify(Arg1, var(Arg2), (In - In),
			simple_test(Arg1, Arg2), unify_context(explicit, [])),
		Info = Info0
	;
		% Look for unification or comparison applied to a no-tag type
		% wrapping a builtin type. 
		% This needs to be done to optimize all the map_lookups
		% with keys of type `term__var/1' in the compiler.
		% (:- type var(T) ---> var(int).)
		% This could possibly be better handled by just inlining 
		% the unification code, but the compiler doesn't have the
		% code for the comparison or in-in unification procedures
		% for imported types, and unification and comparison will
		% eventually be implemented in C code in the runtime system. 
		( SpecialId = unify ; SpecialId = compare ),
		type_constructors(SpecialPredType, ModuleInfo, Constructors),
		type_is_no_tag_type(Constructors, Constructor, WrappedType),
		\+ type_has_user_defined_equality_pred(ModuleInfo,
			WrappedType, _),

		% This could be done for non-atomic types, but it would
		% be a bit more complicated because the type-info for
		% the wrapped type would need to be extracted first.
		type_is_atomic(WrappedType, ModuleInfo)
	->
		(
			SpecialId = unify,
			SpecialPredArgs = [Arg1, Arg2]
		;
			SpecialId = compare,
			SpecialPredArgs = [_, Arg1, Arg2]
		),
		unwrap_no_tag_arg(WrappedType, Constructor, Arg1,
			UnwrappedArg1, ExtractGoal1, ProcInfo0, ProcInfo1),
		unwrap_no_tag_arg(WrappedType, Constructor, Arg2,
			UnwrappedArg2, ExtractGoal2, ProcInfo1, ProcInfo),
		set__list_to_set([UnwrappedArg1, UnwrappedArg2], NonLocals0),
		(
			SpecialId = unify,
			in_mode(In),
			NonLocals = NonLocals0,
			instmap_delta_init_reachable(InstMapDelta),
			Detism = semidet,
			SpecialGoal = unify(UnwrappedArg1, var(UnwrappedArg2),
				(In - In),
				simple_test(UnwrappedArg1, UnwrappedArg2),
				unify_context(explicit, [])) 
		;
			SpecialId = compare,
			SpecialPredArgs = [ComparisonResult, _, _],
			set__insert(NonLocals0, ComparisonResult, NonLocals), 
			NewCallArgs = [ComparisonResult,
				UnwrappedArg1, UnwrappedArg2],
			instmap_delta_from_assoc_list(
				[ComparisonResult - ground(shared, no)],
				InstMapDelta),
			Detism = det,
			% Build a new call with the unwrapped arguments.
			polymorphism__get_special_proc(WrappedType,
				SpecialId, ModuleInfo, SymName,
				SpecialPredId, SpecialProcId),
			SpecialGoal = call(SpecialPredId, SpecialProcId,
				NewCallArgs, not_builtin,
				MaybeContext, SymName)
		),
		goal_info_init(NonLocals, InstMapDelta, Detism, GoalInfo),

		Goal = conj([ExtractGoal1, ExtractGoal2,
				SpecialGoal - GoalInfo]),
		Info = info(PredVars, B, C, D, E, ProcInfo, ModuleInfo, H, I)
	;
		polymorphism__get_special_proc(SpecialPredType, SpecialId,
			ModuleInfo, SymName, SpecialPredId, SpecialProcId),
		( type_is_higher_order(SpecialPredType, _, _, _) ->
			% builtin_*_pred are special cases which
			% doesn't need the type-info arguments.
			CallArgs = SpecialPredArgs
		;
			list__append(TypeInfoArgs, SpecialPredArgs, CallArgs)
		),	
		Goal = call(SpecialPredId, SpecialProcId, CallArgs,
			not_builtin, MaybeContext, SymName),
		Info = Info0
	).

:- pred unwrap_no_tag_arg((type)::in, sym_name::in, prog_var::in,
	prog_var::out, hlds_goal::out, proc_info::in, proc_info::out) is det.

unwrap_no_tag_arg(WrappedType, Constructor, Arg, UnwrappedArg,
		Goal, ProcInfo0, ProcInfo) :-
	proc_info_create_var_from_type(ProcInfo0, WrappedType, UnwrappedArg,
		ProcInfo),
	ConsId = cons(Constructor, 1),
	UniModes = [(ground(shared, no) - free) ->
			(ground(shared, no) - ground(shared, no))],
	in_mode(In),
	out_mode(Out),
	set__list_to_set([Arg, UnwrappedArg], NonLocals),
	% This will be recomputed later.
	instmap_delta_from_assoc_list([UnwrappedArg - ground(shared, no)],
		InstMapDelta),
	goal_info_init(NonLocals, InstMapDelta, det, GoalInfo),
	Goal = unify(Arg, functor(ConsId, [UnwrappedArg]), In - Out,
		deconstruct(Arg, ConsId, [UnwrappedArg], UniModes,
			cannot_fail),
		unify_context(explicit, [])) - GoalInfo.

%-------------------------------------------------------------------------------
% Predicates to process requests for specialization, and create any  
% new predicates that are required.	

		% Filter out requests for higher-order specialization 
		% for preds which are too large. Maybe we could allow
		% programmers to declare which predicates they want
		% specialized, as with inlining?
		% Don't create specialized versions of specialized
		% versions, since for some fairly contrived examples 
		% involving recursively building up lambda expressions
		% this can create ridiculous numbers of versions.
:- pred filter_requests(ho_params::in, module_info::in,
	set(request)::in, goal_sizes::in, list(request)::out,
	io__state::di, io__state::uo) is det.

filter_requests(Params, ModuleInfo, Requests0, GoalSizes, Requests) -->
	{ set__to_sorted_list(Requests0, Requests1) },
	filter_requests_2(Params, ModuleInfo, Requests1, GoalSizes,
		[], Requests).

:- pred filter_requests_2(ho_params::in, module_info::in, list(request)::in,
	goal_sizes::in, list(request)::in, list(request)::out,
	io__state::di, io__state::uo) is det.

filter_requests_2(_, _, [], _, Requests, Requests) --> [].
filter_requests_2(Params, ModuleInfo, [Request | Requests0],
		GoalSizes, FilteredRequests0, FilteredRequests) -->
	{ Params = ho_params(_, _, _, MaxSize, _) },
	{ Request = request(_, CalledPredProcId, _, _, HOArgs,
		_, _, _, IsUserTypeSpec, Context) },
	{ CalledPredProcId = proc(CalledPredId, _) },
	{ module_info_pred_info(ModuleInfo, CalledPredId, PredInfo) },
	globals__io_lookup_bool_option(very_verbose, VeryVerbose),
	{ pred_info_module(PredInfo, PredModule) },
	{ pred_info_name(PredInfo, PredName) },
	{ pred_info_arity(PredInfo, Arity) },
	{ pred_info_arg_types(PredInfo, Types) },
	{ list__length(Types, ActualArity) },
	maybe_write_request(VeryVerbose, ModuleInfo, "Request for",
		qualified(PredModule, PredName), Arity, ActualArity,
		no, HOArgs, Context),
	(
		% Ignore the size limit for user specified specializations.
		{ IsUserTypeSpec = yes }
	->
		maybe_write_string(VeryVerbose,
		"%    request specialized (user-requested specialization)\n"),
		{ FilteredRequests1 = [Request | FilteredRequests0] }
	;
		( { map__search(GoalSizes, CalledPredId, GoalSize) } ->
			( { GoalSize =< MaxSize } ->
				maybe_write_string(VeryVerbose,
				"%    request specialized.\n"),
				{ FilteredRequests1 =
					[Request | FilteredRequests0] }
			;
				{ FilteredRequests1 = FilteredRequests0 },
				maybe_write_string(VeryVerbose,
				"%    not specializing (goal too large).\n")
			)	
		;
			% Previously specialized versions aren't put
			% in the goal_sizes map to ensure that we don't
			% go into an infinite loop by recursively
			% specializing a version.
			{ FilteredRequests1 = FilteredRequests0 },
			maybe_write_string(VeryVerbose,
			"%    not specializing (recursive specialization).\n")
		)
	),
	filter_requests_2(Params, ModuleInfo, Requests0, GoalSizes,
		FilteredRequests1, FilteredRequests).

:- pred create_new_preds(ho_params::in, list(request)::in, new_preds::in,
		new_preds::out, list(new_pred)::in, list(new_pred)::out,
		set(pred_proc_id)::in, set(pred_proc_id)::out, int::in,
		int::out, module_info::in, module_info::out,
		io__state::di, io__state::uo) is det.

create_new_preds(_, [], NewPreds, NewPreds, NewPredList, NewPredList,
		ToFix, ToFix, NextId, NextId, Mod, Mod, IO, IO). 
create_new_preds(Params, [Request | Requests], NewPreds0, NewPreds,
		NewPredList0, NewPredList, PredsToFix0, PredsToFix,
		NextHOid0, NextHOid, Module0, Module, IO0, IO)  :-
	Request = request(CallingPredProcId, CalledPredProcId, _HOArgs,
		_CallArgs, _, _CallerArgTypes, _, _, _, _),
	set__insert(PredsToFix0, CallingPredProcId, PredsToFix1),
	(
		NewPreds0 = new_preds(NewPredMap0, _),
		map__search(NewPredMap0, CalledPredProcId, SpecVersions0)
	->
		(
			% check that we aren't redoing the same pred
			% SpecVersions are pred_proc_ids of the specialized
			% versions of the current pred.
			\+ (
				set__member(Version, SpecVersions0),
				version_matches(Params, Module0,
					Request, Version, _)
			)
		->
			create_new_pred(Request, NewPred, NextHOid0,
				NextHOid1, NewPreds0, NewPreds1,
				Module0, Module1, IO0, IO2), 
			NewPredList1 = [NewPred | NewPredList0]
		;
			Module1 = Module0,
			NewPredList1 = NewPredList0,
			NewPreds1 = NewPreds0,
			IO2 = IO0,
			NextHOid1 = NextHOid0
		)
	;
		create_new_pred(Request, NewPred, NextHOid0, NextHOid1,
			NewPreds0, NewPreds1, Module0, Module1, IO0, IO2),
		NewPredList1 = [NewPred | NewPredList0]
	),
	create_new_preds(Params, Requests, NewPreds1, NewPreds, NewPredList1,
		NewPredList, PredsToFix1, PredsToFix, NextHOid1, NextHOid,
		Module1, Module, IO2, IO).

:- pred add_new_pred(pred_proc_id::in, new_pred::in,
		new_preds::in, new_preds::out) is det.

add_new_pred(CalledPredProcId, NewPred, new_preds(NewPreds0, PredVars),
		new_preds(NewPreds, PredVars)) :-
	( map__search(NewPreds0, CalledPredProcId, SpecVersions0) ->
		set__insert(SpecVersions0, NewPred, SpecVersions)
	;
		set__singleton_set(SpecVersions, NewPred)
	),
	map__set(NewPreds0, CalledPredProcId, SpecVersions, NewPreds).

		% Here we create the pred_info for the new predicate.
:- pred create_new_pred(request::in, new_pred::out, int::in, int::out,
	new_preds::in, new_preds::out, module_info::in,
	module_info::out, io__state::di, io__state::uo) is det.

create_new_pred(Request, NewPred, NextHOid0, NextHOid, NewPreds0, NewPreds,
		ModuleInfo0, ModuleInfo, IOState0, IOState) :- 
	Request = request(Caller, CalledPredProc, CallArgs, ExtraTypeInfoTVars,
			HOArgs, ArgTypes, TypeInfoLiveness,
			CallerTVarSet, IsUserTypeSpec, Context),
	module_info_pred_proc_info(ModuleInfo0, CalledPredProc,
		PredInfo0, ProcInfo0),

	pred_info_name(PredInfo0, Name0),
	pred_info_arity(PredInfo0, Arity),
	pred_info_get_is_pred_or_func(PredInfo0, PredOrFunc),
	pred_info_module(PredInfo0, PredModule),
	globals__io_lookup_bool_option(very_verbose, VeryVerbose,
							IOState0, IOState1),
        pred_info_arg_types(PredInfo0, ArgTVarSet, ExistQVars, Types),

	( IsUserTypeSpec = yes ->
		% If this is a user-guided type specialisation, the
		% new name comes from the name of the requesting predicate.
		Caller = proc(CallerPredId, CallerProcId),
		predicate_name(ModuleInfo0, CallerPredId, PredName),
		SymName = qualified(PredModule, PredName),
		NextHOid = NextHOid0,
		NewProcId = CallerProcId,
		% For exported predicates the type specialization must
		% be exported.
		% For opt_imported predicates we only want to keep this
		% version if we do some other useful specialization on it.
		pred_info_import_status(PredInfo0, Status)
	;
		hlds_pred__initial_proc_id(NewProcId),
		string__int_to_string(NextHOid0, IdStr),
		NextHOid is NextHOid0 + 1,
		string__append_list([Name0, "__ho", IdStr], PredName),
		SymName = qualified(PredModule, PredName),
		Status = local
	),

	list__length(Types, ActualArity),
	maybe_write_request(VeryVerbose, ModuleInfo, "Specializing",
		qualified(PredModule, Name0), Arity, ActualArity,
		yes(PredName), HOArgs, Context, IOState1, IOState),

	pred_info_typevarset(PredInfo0, TypeVarSet),
	pred_info_get_markers(PredInfo0, MarkerList),
	pred_info_get_goal_type(PredInfo0, GoalType),
	pred_info_get_class_context(PredInfo0, ClassContext),
	pred_info_get_aditi_owner(PredInfo0, Owner),
	varset__init(EmptyVarSet),
	map__init(EmptyVarTypes),
	map__init(EmptyProofs),
	map__init(EmptyTIMap),
	map__init(EmptyTCIMap),
	
	% This isn't looked at after here, and just clutters up
	% hlds dumps if it's filled in.
	ClausesInfo = clauses_info(EmptyVarSet, EmptyVarTypes,
		EmptyVarTypes, [], [], EmptyTIMap, EmptyTCIMap),
	pred_info_init(PredModule, SymName, Arity, ArgTVarSet, ExistQVars,
		Types, true, Context, ClausesInfo, Status, MarkerList, GoalType,
		PredOrFunc, ClassContext, EmptyProofs, Owner, NewPredInfo0),
	pred_info_set_typevarset(NewPredInfo0, TypeVarSet, NewPredInfo1),

	module_info_get_predicate_table(ModuleInfo0, PredTable0),
	predicate_table_insert(PredTable0, NewPredInfo1, NewPredId, PredTable),
	module_info_set_predicate_table(ModuleInfo0, PredTable, ModuleInfo1),

	NewPred = new_pred(proc(NewPredId, NewProcId), CalledPredProc, Caller,
		SymName, HOArgs, CallArgs, ExtraTypeInfoTVars, ArgTypes,
		TypeInfoLiveness, CallerTVarSet, IsUserTypeSpec),

	add_new_pred(CalledPredProc, NewPred, NewPreds0, NewPreds1),

	create_new_proc(ModuleInfo0, NewPred, ProcInfo0,
		NewPredInfo1, NewPredInfo, NewPreds1, NewPreds),
	module_info_set_pred_info(ModuleInfo1, NewPredId, NewPredInfo,
		ModuleInfo).

:- pred maybe_write_request(bool::in, module_info::in, string::in,
	sym_name::in, arity::in, arity::in, maybe(string)::in,
	list(higher_order_arg)::in, prog_context::in,
	io__state::di, io__state::uo) is det.

maybe_write_request(no, _, _, _, _, _, _, _, _) --> [].
maybe_write_request(yes, ModuleInfo, Msg, SymName,
		Arity, ActualArity, MaybeNewName, HOArgs, Context) -->
	{ prog_out__sym_name_to_string(SymName, OldName) },
	{ string__int_to_string(Arity, ArStr) },
	io__write_string("% "),
	prog_out__write_context(Context),
	io__write_strings([Msg, " `", OldName, "'/", ArStr]),

	( { MaybeNewName = yes(NewName) } ->
		io__write_string(" into "),
		io__write_string(NewName)
	;
		[]
	),
	io__write_string(" with higher-order arguments:\n"),
	{ NumToDrop is ActualArity - Arity },
	output_higher_order_args(ModuleInfo, NumToDrop, HOArgs).

:- pred output_higher_order_args(module_info::in, int::in,
	list(higher_order_arg)::in, io__state::di, io__state::uo) is det.

output_higher_order_args(_, _, []) --> [].
output_higher_order_args(ModuleInfo, NumToDrop, [HOArg | HOArgs]) -->
	{ HOArg = higher_order_arg(ConsId, ArgNo, NumArgs, _, _, _) },
	( { ConsId = pred_const(PredId, _ProcId, _) } ->
		{ module_info_pred_info(ModuleInfo, PredId, PredInfo) },
		{ pred_info_name(PredInfo, Name) },
		{ pred_info_arity(PredInfo, Arity) },
			% adjust message for type_infos
		{ DeclaredArgNo is ArgNo - NumToDrop },
		io__write_string("\tHeadVar__"),
		io__write_int(DeclaredArgNo),
		io__write_string(" = `"),
		io__write_string(Name),
		io__write_string("'/"),
		io__write_int(Arity)
	; { ConsId = type_ctor_info_const(TypeModule, TypeName, TypeArity) } ->
		io__write_string(" type_ctor_info for `"),
		prog_out__write_sym_name(qualified(TypeModule, TypeName)),
		io__write_string("'/"),
		io__write_int(TypeArity)
	; { ConsId = base_typeclass_info_const(_, ClassId, _, _) } ->
		io__write_string(" base_typeclass_info for `"),
		{ ClassId = class_id(ClassName, ClassArity) },
		prog_out__write_sym_name(ClassName),
		io__write_string("'/"),
		io__write_int(ClassArity)
	;
		% XXX output the type.
		io__write_string(" type_info/typeclass_info ")
	),
	io__write_string(" with "),
	io__write_int(NumArgs),
	io__write_string(" curried arguments\n"),
	output_higher_order_args(ModuleInfo, NumToDrop, HOArgs).

%-----------------------------------------------------------------------------%

:- pred fixup_preds(ho_params::in, list(pred_proc_id)::in, new_preds::in,
		module_info::in, module_info::out) is det.

fixup_preds(Params, PredProcIds, NewPreds, ModuleInfo0, ModuleInfo) :-
	set__init(Requests0),
	MustRecompute = no,
	fixup_preds(MustRecompute, Params, PredProcIds, NewPreds, Requests0, _, 
		ModuleInfo0, ModuleInfo).

:- pred fixup_specialized_versions(ho_params::in, list(new_pred)::in,
		new_preds::in, set(request)::in, set(request)::out,
		module_info::in, module_info::out) is det.

fixup_specialized_versions(Params, NewPredList, NewPreds,
		Requests0, Requests, ModuleInfo0, ModuleInfo) :-
	list__map(
		(pred(NewPred::in, PredProcId::out) is det :-
			NewPred = new_pred(PredProcId, _, _,
					_, _, _, _, _, _, _, _)
		),
		NewPredList, NewPredProcIds),

	%
	% Reprocess the goals to find any new specializations made
	% possible by the specializations performed in this pass.
	%
	MustRecompute = yes,
	fixup_preds(MustRecompute, Params, NewPredProcIds, NewPreds,
		Requests0, Requests, ModuleInfo0, ModuleInfo).

	% Fixup calls to specialized predicates.
:- pred fixup_preds(bool::in, ho_params::in, list(pred_proc_id)::in,
		new_preds::in, set(request)::in, set(request)::out,
		module_info::in, module_info::out) is det.

fixup_preds(_, _Params, [], _, Requests, Requests, ModuleInfo, ModuleInfo).
fixup_preds(MustRecompute, Params, [PredProcId | PredProcIds], NewPreds,
		Requests0, Requests, ModuleInfo0, ModuleInfo) :-
	module_info_pred_proc_info(ModuleInfo0, PredProcId,
		PredInfo0, ProcInfo0),
	map__init(PredVars0),
	Info0 = info(PredVars0, Requests0, NewPreds, PredProcId,
			PredInfo0, ProcInfo0, ModuleInfo0, Params, unchanged),
	traverse_goal(MustRecompute, Info0, Info),
	Info = info(_, Requests1, _, _, PredInfo, ProcInfo, ModuleInfo1, _, _),
	module_info_set_pred_proc_info(ModuleInfo1, PredProcId, PredInfo,
		ProcInfo, ModuleInfo2),
	fixup_preds(MustRecompute, Params, PredProcIds, NewPreds,
		Requests1, Requests, ModuleInfo2, ModuleInfo).

%-----------------------------------------------------------------------------%

	% Build a proc_info for a specialized version.
:- pred create_new_proc(module_info::in, new_pred::in, proc_info::in,
	pred_info::in, pred_info::out, new_preds::in, new_preds::out) is det.

create_new_proc(ModuleInfo, NewPred, NewProcInfo0, NewPredInfo0, NewPredInfo,
		NewPreds0, NewPreds) :-
	NewPred = new_pred(NewPredProcId, _, Caller, _Name,
		HOArgs0, CallArgs, ExtraTypeInfoTVars0, CallerArgTypes0,
		_, _, _),

	proc_info_headvars(NewProcInfo0, HeadVars0),
	proc_info_argmodes(NewProcInfo0, ArgModes0),
	pred_info_arg_types(NewPredInfo0, _, ExistQVars0, _),
	pred_info_typevarset(NewPredInfo0, TypeVarSet0),

	Caller = proc(CallerPredId, CallerProcId),
	module_info_pred_proc_info(ModuleInfo, CallerPredId, CallerProcId,
		CallerPredInfo, CallerProcInfo),
	pred_info_arg_types(CallerPredInfo, CallerTypeVarSet, _, _),
	pred_info_get_head_type_params(CallerPredInfo, CallerHeadParams),
	proc_info_typeinfo_varmap(CallerProcInfo, CallerTypeInfoVarMap0),

	%
	% Specialize the types of the called procedure as for inlining.
	%
	proc_info_vartypes(NewProcInfo0, VarTypes0),
	varset__merge_subst(CallerTypeVarSet, TypeVarSet0,
		TypeVarSet, TypeRenaming), 
        apply_substitution_to_type_map(VarTypes0, TypeRenaming, VarTypes1),

	% the real set of existentially quantified variables may be
	% smaller, but this is OK
	map__apply_to_list(ExistQVars0, TypeRenaming, ExistQTerms),
	term__term_list_to_var_list(ExistQTerms, ExistQVars),

        map__apply_to_list(HeadVars0, VarTypes1, HeadTypes0),
	inlining__get_type_substitution(HeadTypes0, CallerArgTypes0,
		CallerHeadParams, ExistQVars, TypeSubn),

	term__var_list_to_term_list(ExtraTypeInfoTVars0,
		ExtraTypeInfoTVarTypes0),
	
	apply_rec_substitution_to_type_map(VarTypes1, TypeSubn, VarTypes2),
	proc_info_set_vartypes(NewProcInfo0, VarTypes2, NewProcInfo1),

	( (map__is_empty(TypeSubn) ; ExistQVars = []) ->
		HOArgs = HOArgs0,
		ExtraTypeInfoTVarTypes = ExtraTypeInfoTVarTypes0,
		ExtraTypeInfoTVars = ExtraTypeInfoTVars0
	;	
		% If there are existentially quantified variables in the
		% callee we may need to bind type variables in the caller.
		list__map(substitute_higher_order_arg(TypeSubn),
			HOArgs0, HOArgs),
		
		term__apply_rec_substitution_to_list(ExtraTypeInfoTVarTypes0,
			TypeSubn, ExtraTypeInfoTVarTypes),
		% The substitution should never bind any of the type variables
		% for which extra type-infos are needed, otherwise it
		% wouldn't be necessary to add them.
		term__term_list_to_var_list(ExtraTypeInfoTVarTypes,
			ExtraTypeInfoTVars)
	),

	% Add in the extra typeinfo vars.
	list__map(polymorphism__build_type_info_type,
		ExtraTypeInfoTVarTypes, ExtraTypeInfoTypes),
	proc_info_create_vars_from_types(NewProcInfo1, ExtraTypeInfoTypes,
		ExtraTypeInfoVars, NewProcInfo2),

	map__from_corresponding_lists(CallArgs, HeadVars0, VarRenaming0),

	% Construct the constant input closures within the goal
	% for the called procedure.
	map__init(PredVars0),
	construct_higher_order_terms(ModuleInfo, HeadVars0, HeadVars1,
		ArgModes0, ArgModes1, HOArgs, NewProcInfo2, NewProcInfo3,
		VarRenaming0, VarRenaming, PredVars0, PredVars),

	% Let traverse_goal know about the constant input arguments.
	NewPreds0 = new_preds(A, PredVarMap0),
	map__det_insert(PredVarMap0, NewPredProcId, PredVars, PredVarMap),
	NewPreds = new_preds(A, PredVarMap),	

	%
	% Fix up the typeinfo_varmap. 
	%
	proc_info_typeinfo_varmap(NewProcInfo3, TypeInfoVarMap0),

	% Restrict the caller's typeinfo_varmap
	% down onto the arguments of the call.
	map__to_assoc_list(CallerTypeInfoVarMap0, TypeInfoAL0),
	list__filter(
		(pred(TVarAndLocn::in) is semidet :-
			TVarAndLocn = _ - Locn,
			type_info_locn_var(Locn, LocnVar),
			map__contains(VarRenaming, LocnVar)
		), TypeInfoAL0, TypeInfoAL),
	map__from_assoc_list(TypeInfoAL, CallerTypeInfoVarMap1),

	% The type renaming doesn't rename type variables in the caller.
	map__init(EmptyTypeRenaming),
	apply_substitutions_to_var_map(CallerTypeInfoVarMap1,
		EmptyTypeRenaming, TypeSubn, VarRenaming,
		CallerTypeInfoVarMap),
	% The variable renaming doesn't rename variables in the callee.
	map__init(EmptyVarRenaming),
	apply_substitutions_to_var_map(TypeInfoVarMap0, TypeRenaming,
		TypeSubn, EmptyVarRenaming, TypeInfoVarMap1),
	map__merge(TypeInfoVarMap1, CallerTypeInfoVarMap,
		TypeInfoVarMap2),

	% Add entries in the typeinfo_varmap for the extra type-infos.
	list__map(
		(pred(TypeInfoVar::in, type_info(TypeInfoVar)::out) is det),
		ExtraTypeInfoVars, ExtraTypeInfoLocns),
	map__from_corresponding_lists(ExtraTypeInfoTVars, ExtraTypeInfoLocns,
		ExtraTypeInfoMap),
	map__overlay(TypeInfoVarMap2, ExtraTypeInfoMap, TypeInfoVarMap),

	proc_info_set_typeinfo_varmap(NewProcInfo3,
		TypeInfoVarMap, NewProcInfo4),

	%
	% Fix up the argument vars, types and modes.
	%

	in_mode(InMode),
	list__length(ExtraTypeInfoVars, NumTypeInfos),
	list__duplicate(NumTypeInfos, InMode, ExtraTypeInfoModes),
	list__append(ExtraTypeInfoVars, HeadVars1, HeadVars),
	list__append(ExtraTypeInfoModes, ArgModes1, ArgModes),
	proc_info_set_headvars(NewProcInfo4, HeadVars, NewProcInfo5),
	proc_info_set_argmodes(NewProcInfo5, ArgModes, NewProcInfo6),

	proc_info_vartypes(NewProcInfo6, VarTypes6),
	map__apply_to_list(HeadVars, VarTypes6, ArgTypes),
	pred_info_set_arg_types(NewPredInfo0, TypeVarSet,
		ExistQVars, ArgTypes, NewPredInfo1),
	pred_info_set_typevarset(NewPredInfo1, TypeVarSet, NewPredInfo2),

	%
	% Apply the substitutions to the types in the original
	% typeclass_info_varmap.
	%
	proc_info_typeclass_info_varmap(NewProcInfo6, TCVarMap0),
	apply_substitutions_to_typeclass_var_map(TCVarMap0, TypeRenaming,
		TypeSubn, EmptyVarRenaming, TCVarMap),
	proc_info_set_typeclass_info_varmap(NewProcInfo6,
		TCVarMap, NewProcInfo7),

	%
	% Find the new class context by searching the argument types
	% for typeclass_infos (the corresponding constraint is encoded
	% in the type of a typeclass_info).
	%
	find_class_context(ModuleInfo, ArgTypes, ArgModes,
		[], [], ClassContext),
	pred_info_set_class_context(NewPredInfo2, ClassContext, NewPredInfo3),

	map__init(NewProcs0),
	NewPredProcId = proc(_, NewProcId),
	map__det_insert(NewProcs0, NewProcId, NewProcInfo7, NewProcs),
	pred_info_set_procedures(NewPredInfo3, NewProcs, NewPredInfo).

		% Take an original list of headvars and arg_modes and
		% return these with curried arguments added.
		% The old higher-order arguments are left in. They may be
		% needed in calls which could not be specialised. If not,
		% unused_args.m can clean them up.
		%
		% Build the initial pred_vars map which records
		% higher-order and type_info constants for a call to
		% traverse_goal.
		%	
		% Build a var-var renaming from the requesting
		% call's arguments to the headvars of the specialized
		% version.
		%
		% This predicate is recursively applied to all curried
		% higher order arguments of higher order arguments.
:- pred construct_higher_order_terms(module_info::in, list(prog_var)::in, 
		list(prog_var)::out, list(mode)::in, list(mode)::out,
		list(higher_order_arg)::in, proc_info::in, proc_info::out,
		map(prog_var, prog_var)::in, map(prog_var, prog_var)::out,
		pred_vars::in, pred_vars::out) is det.

construct_higher_order_terms(_, HeadVars, HeadVars, ArgModes, ArgModes,
		[], ProcInfo, ProcInfo, Renaming, Renaming,
		PredVars, PredVars).
construct_higher_order_terms(ModuleInfo, HeadVars0, HeadVars, ArgModes0,
		ArgModes, [HOArg | HOArgs], ProcInfo0, ProcInfo,
		Renaming0, Renaming, PredVars0, PredVars) :-
	HOArg = higher_order_arg(ConsId, Index, NumArgs,
		CurriedArgs, CurriedArgTypes, CurriedHOArgs),

	list__index1_det(HeadVars0, Index, LVar),
	(
		( ConsId = pred_const(PredId, ProcId, _)
		; ConsId = code_addr_const(PredId, ProcId)
		)
	->
		% Add the curried arguments to the procedure's argument list.
		module_info_pred_proc_info(ModuleInfo, PredId, ProcId,
			_CalledPredInfo, CalledProcInfo),
		proc_info_argmodes(CalledProcInfo, CalledArgModes),
		( list__take(NumArgs, CalledArgModes, CurriedArgModes0) ->
			CurriedArgModes1 = CurriedArgModes0
		;
			error("list__split_list_failed")
		)
	;
		in_mode(InMode),
		list__duplicate(NumArgs, InMode, CurriedArgModes1)
	),

	proc_info_create_vars_from_types(ProcInfo0, CurriedArgTypes,
		NewHeadVars0, ProcInfo1),

	% Make traverse_goal pretend that the input higher-order argument is
	% built using the new arguments as its curried arguments.
	map__det_insert(PredVars0, LVar,
		constant(ConsId, NewHeadVars0), PredVars1),

	assoc_list__from_corresponding_lists(CurriedArgs,
		NewHeadVars0, CurriedRenaming),
	list__foldl(
		(pred(VarPair::in, Map0::in, Map::out) is det :-
			VarPair = Var1 - Var2,
			map__set(Map0, Var1, Var2, Map)
		), CurriedRenaming, Renaming0, Renaming1),

	% Recursively construct the curried higher-order arguments.
	construct_higher_order_terms(ModuleInfo, NewHeadVars0, NewHeadVars,
		CurriedArgModes1, CurriedArgModes, CurriedHOArgs,
		ProcInfo1, ProcInfo2, Renaming1, Renaming2,
		PredVars1, PredVars2),

	% Fix up the argument lists.
	list__append(ArgModes0, CurriedArgModes, ArgModes1),
	list__append(HeadVars0, NewHeadVars, HeadVars1),

	construct_higher_order_terms(ModuleInfo, HeadVars1, HeadVars,
		ArgModes1, ArgModes, HOArgs, ProcInfo2, ProcInfo,
		Renaming2, Renaming, PredVars2, PredVars).

%-----------------------------------------------------------------------------%

	% Substitute the types in a higher_order_arg.
:- pred substitute_higher_order_arg(tsubst::in, higher_order_arg::in, 
		higher_order_arg::out) is det.

substitute_higher_order_arg(Subn, HOArg0, HOArg) :-
	HOArg0 = higher_order_arg(A, B, C, D,
		CurriedArgTypes0, CurriedHOArgs0),
	term__apply_rec_substitution_to_list(CurriedArgTypes0,
		Subn, CurriedArgTypes),
	list__map(substitute_higher_order_arg(Subn),
		CurriedHOArgs0, CurriedHOArgs),
	HOArg = higher_order_arg(A, B, C, D,
		CurriedArgTypes, CurriedHOArgs).

%-----------------------------------------------------------------------------%

	% Collect the list of class_constraints from the list of argument
	% types. The typeclass_info for universal constraints is input,
	% output for existential constraints.
:- pred find_class_context(module_info::in, list(type)::in, list(mode)::in,
	list(class_constraint)::in, list(class_constraint)::in,
	class_constraints::out) is det.

find_class_context(_, [], [], Univ0, Exist0, Constraints) :-
	list__reverse(Univ0, Univ),
	list__reverse(Exist0, Exist),
	Constraints = constraints(Univ, Exist).
find_class_context(_, [], [_|_], _, _, _) :-
	error("higher_order:find_class_context").
find_class_context(_, [_|_], [], _, _, _) :-
	error("higher_order:find_class_context").
find_class_context(ModuleInfo, [Type | Types], [Mode | Modes],
		Univ0, Exist0, Constraints) :-
	( polymorphism__typeclass_info_class_constraint(Type, Constraint) ->
		( mode_is_input(ModuleInfo, Mode) ->
			maybe_add_constraint(Univ0, Constraint, Univ),
			Exist = Exist0
		;
			maybe_add_constraint(Exist0, Constraint, Exist),
			Univ = Univ0
		)
	;
		Univ = Univ0,
		Exist = Exist0
	),
	find_class_context(ModuleInfo, Types, Modes, Univ, Exist, Constraints).

:- pred maybe_add_constraint(list(class_constraint)::in,
		class_constraint::in, list(class_constraint)::out) is det.

maybe_add_constraint(Constraints0, Constraint0, Constraints) :-
	Constraint0 = constraint(ClassName, Types0),
	strip_prog_contexts(Types0, Types),
	Constraint = constraint(ClassName, Types),
	(
		% Remove duplicates.
		\+ list__member(Constraint, Constraints0)
	->
		Constraints = [Constraint | Constraints0]	
	;
		Constraints = Constraints0		
	).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
