%-----------------------------------------------------------------------------%
% Copyright (C) 1997-2003 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% term_util.m
% Main author: crs.
%
% This module:
%
% -	defines the types used by termination analysis
% -	defines some utility predicates
%
%-----------------------------------------------------------------------------%

:- module transform_hlds__term_util.

:- interface.

:- import_module hlds__hlds_goal.
:- import_module hlds__hlds_module.
:- import_module hlds__hlds_pred.
:- import_module parse_tree__prog_data.
:- import_module transform_hlds__term_errors.
:- import_module transform_hlds__term_norm.

:- import_module std_util, bool, int, list, map, bag.

%-----------------------------------------------------------------------------%
%
% The types `arg_size_info' and `termination_info' hold information
% about procedures which is used for termination analysis.
% These types are stored as fields in the HLDS proc_info.
% For cross-module analysis, the information is written out as
% `pragma termination_info(...)' declarations in the
% `.opt' and `.trans_opt' files.  The module prog_data.m defines
% types similar to these two (but without the `list(term_errors__error)')
% which are used when parsing `termination_info' pragmas.
%

% The arg size info defines an upper bound on the difference
% between the sizes of the output arguments of a procedure and the sizes
% of the input arguments:
%
% | input arguments | + constant >= | output arguments |
%
% where | | represents a semilinear norm.

:- type arg_size_info
	--->	finite(int, list(bool))
				% The termination constant is a finite integer.
				% The list of bool has a 1:1 correspondence
				% with the input arguments of the procedure.
				% It stores whether the argument contributes
				% to the size of the output arguments.

	;	infinite(list(term_errors__error)).
				% There is no finite integer for which the
				% above equation is true. The argument says
				% why the analysis failed to find a finite
				% constant.

:- type termination_info
	---> 	cannot_loop	% This procedure terminates for all
				% possible inputs.

	;	can_loop(list(term_errors__error)).
				% The analysis could not prove that the
				% procedure terminates.

% The type `used_args' holds a mapping which specifies for each procedure
% which of its arguments are used.

:- type used_args	==	map(pred_proc_id, list(bool)).

:- type pass_info
	--->	pass_info(
			functor_info,
			int,		% Max number of errors to gather.
			int		% Max number of paths to analyze.
		).

%-----------------------------------------------------------------------------%

% This predicate partitions the arguments of a call into a list of input
% variables and a list of output variables,

:- pred partition_call_args(module_info::in, list(mode)::in, list(prog_var)::in,
	bag(prog_var)::out, bag(prog_var)::out) is det.

% Given a list of variables from a unification, this predicate divides the
% list into a bag of input variables, and a bag of output variables.

:- pred split_unification_vars(list(prog_var)::in, list(uni_mode)::in,
	module_info::in, bag(prog_var)::out, bag(prog_var)::out) is det.

%  Used to create lists of boolean values, which are used for used_args.
%  make_bool_list(HeadVars, BoolIn, BoolOut) creates a bool list which is
%  (length(HeadVars) - length(BoolIn)) `no' followed by BoolIn.  This is
%  used to set the used args for compiler generated predicates.  The no's
%  at the start are because the Type infos are not used. length(BoolIn)
%  should equal the arity of the predicate, and the difference in length
%  between the arity of the procedure and the arity of the predicate is
%  the number of type infos.

:- pred term_util__make_bool_list(list(_T)::in, list(bool)::in,
	list(bool)::out) is det.

% Removes variables from the InVarBag that are not used in the call.
% remove_unused_args(InVarBag0, VarList, BoolList, InVarBag)
% VarList and BoolList are corresponding lists.  Any variable in VarList
% that has a `no' in the corresponding place in the BoolList is removed
% from InVarBag.

:- pred remove_unused_args(bag(prog_var), list(prog_var), list(bool),
		bag(prog_var)).
:- mode remove_unused_args(in, in, in, out) is det.

% This predicate sets the argument size info of a given a list of procedures.

:- pred set_pred_proc_ids_arg_size_info(list(pred_proc_id)::in,
	arg_size_info::in, module_info::in, module_info::out) is det.

% This predicate sets the termination info of a given a list of procedures.

:- pred set_pred_proc_ids_termination_info(list(pred_proc_id)::in,
	termination_info::in, module_info::in, module_info::out) is det.

:- pred lookup_proc_termination_info(module_info::in, pred_proc_id::in,
	maybe(termination_info)::out) is det.

:- pred lookup_proc_arg_size_info(module_info::in, pred_proc_id::in,
	maybe(arg_size_info)::out) is det.

% Succeeds if one or more variables in the list are higher order.

:- pred horder_vars(list(prog_var), map(prog_var, type)).
:- mode horder_vars(in, in) is semidet.

:- pred get_context_from_scc(list(pred_proc_id)::in, module_info::in,
	prog_context::out) is det.

%-----------------------------------------------------------------------------%

% Convert a prog_data__pragma_termination_info into a
% term_util__termination_info, by adding the appropriate context.

:- pred add_context_to_termination_info(maybe(pragma_termination_info),
		prog_context, maybe(termination_info)).
:- mode add_context_to_termination_info(in, in, out) is det.

% Convert a prog_data__pragma_arg_size_info into a
% term_util__arg_size_info, by adding the appropriate context.

:- pred add_context_to_arg_size_info(maybe(pragma_arg_size_info),
		prog_context, maybe(arg_size_info)).
:- mode add_context_to_arg_size_info(in, in, out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module check_hlds__inst_match.
:- import_module check_hlds__mode_util.
:- import_module check_hlds__type_util.
:- import_module libs__globals.
:- import_module libs__options.
:- import_module parse_tree__prog_out.

:- import_module assoc_list, require.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

partition_call_args(Module, ArgModes, Args, InVarsBag, OutVarsBag) :-
	partition_call_args_2(Module, ArgModes, Args, InVars, OutVars),
	bag__from_list(InVars, InVarsBag),
	bag__from_list(OutVars, OutVarsBag).

:- pred partition_call_args_2(module_info::in, list(mode)::in,
	list(prog_var)::in, list(prog_var)::out, list(prog_var)::out) is det.

partition_call_args_2(_, [], [], [], []).
partition_call_args_2(_, [], [_ | _], _, _) :-
	error("Unmatched variables in term_util:partition_call_args").
partition_call_args_2(_, [_ | _], [], _, _) :-
	error("Unmatched variables in term_util__partition_call_args").
partition_call_args_2(ModuleInfo, [ArgMode | ArgModes], [Arg | Args],
		InputArgs, OutputArgs) :-
	partition_call_args_2(ModuleInfo, ArgModes, Args,
		InputArgs1, OutputArgs1),
	( mode_is_input(ModuleInfo, ArgMode) ->
		InputArgs = [Arg | InputArgs1],
		OutputArgs = OutputArgs1
	; mode_is_output(ModuleInfo, ArgMode) ->
		InputArgs = InputArgs1,
		OutputArgs = [Arg | OutputArgs1]
	;
		InputArgs = InputArgs1,
		OutputArgs = OutputArgs1
	).

% For these next two predicates (split_unification_vars and
% partition_call_args) there is a problem of what needs to be done for
% partially instantiated data structures.  The correct answer is that the
% system shoud use a norm such that the size of the uninstantiated parts of
% a partially instantiated structure have no effect on the size of the data
% structure according to the norm.  For example when finding the size of a
% list-skeleton, list-length norm should be used.  Therefore, the size of
% any term must be given by
% sizeof(term) = constant + sum of the size of each
% 			(possibly partly) instantiated subterm.
% It is probably easiest to implement this by modifying term_weights.
% The current implementation does not correctly handle partially
% instantiated data structures.

split_unification_vars([], Modes, _ModuleInfo, Vars, Vars) :-
	bag__init(Vars),
	( Modes = [] ->
		true
	;
		error("term_util:split_unification_vars: Unmatched Variables")
	).
split_unification_vars([Arg | Args], Modes, ModuleInfo,
		InVars, OutVars):-
	( Modes = [UniMode | UniModes] ->
		split_unification_vars(Args, UniModes, ModuleInfo,
			InVars0, OutVars0),
		UniMode = ((_VarInit - ArgInit) -> (_VarFinal - ArgFinal)),
		( % if
			inst_is_bound(ModuleInfo, ArgInit)
		->
			% Variable is an input variable
			bag__insert(InVars0, Arg, InVars),
			OutVars = OutVars0
		; % else if
			inst_is_free(ModuleInfo, ArgInit),
			inst_is_bound(ModuleInfo, ArgFinal)
		->
			% Variable is an output variable
			InVars = InVars0,
			bag__insert(OutVars0, Arg, OutVars)
		; % else
			InVars = InVars0,
			OutVars = OutVars0
		)
	;
		error("term_util__split_unification_vars: Unmatched Variables")
	).

%-----------------------------------------------------------------------------%

term_util__make_bool_list(HeadVars0, Bools, Out) :-
	list__length(Bools, Arity),
	( list__drop(Arity, HeadVars0, HeadVars1) ->
		HeadVars = HeadVars1
	;
		error("Unmatched variables in term_util:make_bool_list")
	),
	term_util__make_bool_list_2(HeadVars, Bools, Out).

:- pred term_util__make_bool_list_2(list(_T), list(bool), list(bool)).
:- mode term_util__make_bool_list_2(in, in, out) is det.

term_util__make_bool_list_2([], Bools, Bools).
term_util__make_bool_list_2([ _ | Vars ], Bools, [no | Out]) :-
	term_util__make_bool_list_2(Vars, Bools, Out).

remove_unused_args(Vars, [], [], Vars).
remove_unused_args(Vars, [], [_X | _Xs], Vars) :-
	error("Unmatched variables in term_util:remove_unused_args").
remove_unused_args(Vars, [_X | _Xs], [], Vars) :-
	error("Unmatched variables in term_util__remove_unused_args").
remove_unused_args(Vars0, [ Arg | Args ], [ UsedVar | UsedVars ], Vars) :-
	( UsedVar = yes ->
		% The variable is used, so leave it
		remove_unused_args(Vars0, Args, UsedVars, Vars)
	;
		% The variable is not used in producing output vars, so
		% dont include it as an input variable.
		bag__delete(Vars0, Arg, Vars1),
		remove_unused_args(Vars1, Args, UsedVars, Vars)
	).

%-----------------------------------------------------------------------------%

set_pred_proc_ids_arg_size_info([], _ArgSize, !Module).
set_pred_proc_ids_arg_size_info([PPId | PPIds], ArgSize, !Module) :-
	PPId = proc(PredId, ProcId),
	module_info_preds(!.Module, PredTable0),
	map__lookup(PredTable0, PredId, PredInfo0),
	pred_info_procedures(PredInfo0, ProcTable0),
	map__lookup(ProcTable0, ProcId, ProcInfo0),

	proc_info_set_maybe_arg_size_info(yes(ArgSize), ProcInfo0, ProcInfo),

	map__det_update(ProcTable0, ProcId, ProcInfo, ProcTable),
	pred_info_set_procedures(ProcTable, PredInfo0, PredInfo),
	map__det_update(PredTable0, PredId, PredInfo, PredTable),
	module_info_set_preds(PredTable, !Module),
	set_pred_proc_ids_arg_size_info(PPIds, ArgSize, !Module).

set_pred_proc_ids_termination_info([], _Termination, !Module).
set_pred_proc_ids_termination_info([PPId | PPIds], Termination, !Module) :-
	PPId = proc(PredId, ProcId),
	module_info_preds(!.Module, PredTable0),
	map__lookup(PredTable0, PredId, PredInfo0),
	pred_info_procedures(PredInfo0, ProcTable0),
	map__lookup(ProcTable0, ProcId, ProcInfo0),

	proc_info_set_maybe_termination_info(yes(Termination),
		ProcInfo0, ProcInfo),

	map__det_update(ProcTable0, ProcId, ProcInfo, ProcTable),
	pred_info_set_procedures(ProcTable, PredInfo0, PredInfo),
	map__det_update(PredTable0, PredId, PredInfo, PredTable),
	module_info_set_preds(PredTable, !Module),
	set_pred_proc_ids_termination_info(PPIds, Termination, !Module).

lookup_proc_termination_info(Module, PredProcId, MaybeTermination) :-
	PredProcId = proc(PredId, ProcId),
	module_info_pred_proc_info(Module, PredId, ProcId, _, ProcInfo),
	proc_info_get_maybe_termination_info(ProcInfo, MaybeTermination).

lookup_proc_arg_size_info(Module, PredProcId, MaybeArgSize) :-
	PredProcId = proc(PredId, ProcId),
	module_info_pred_proc_info(Module, PredId, ProcId, _, ProcInfo),
	proc_info_get_maybe_arg_size_info(ProcInfo, MaybeArgSize).

horder_vars([Arg | Args], VarType) :-
	(
		map__lookup(VarType, Arg, Type),
		type_is_higher_order(Type, _, _, _, _)
	;
		horder_vars(Args, VarType)
	).

%-----------------------------------------------------------------------------%

get_context_from_scc(SCC, Module, Context) :-
	( SCC = [proc(PredId, _) | _] ->
		module_info_pred_info(Module, PredId, PredInfo),
		pred_info_context(PredInfo, Context)
	;
		error("Empty SCC in pass 2 of termination analysis")
	).

%-----------------------------------------------------------------------------%

add_context_to_termination_info(no, _, no).
add_context_to_termination_info(yes(cannot_loop), _, yes(cannot_loop)).
add_context_to_termination_info(yes(can_loop), Context,
		yes(can_loop([Context - imported_pred]))).

add_context_to_arg_size_info(no, _, no).
add_context_to_arg_size_info(yes(finite(A, B)), _, yes(finite(A, B))).
add_context_to_arg_size_info(yes(infinite), Context,
				yes(infinite([Context - imported_pred]))).

%-----------------------------------------------------------------------------%
