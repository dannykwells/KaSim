open Mods
open Mixture
open Dynamics
open Misc
open Ast

type context =
	{ pairing : link IntMap.t; curr_id : int; new_edges : (int * int) Int2Map.t
	}

and link =
	| Closed | Semi of int * int * position

let eval_intf ast_intf =
	let rec iter ast_intf map =
		match ast_intf with
		| Ast.PORT_SEP (p, ast_interface) ->
				let int_state_list = p.Ast.port_int
				and lnk_state = p.Ast.port_lnk
				in
				if StringMap.mem p.Ast.port_nme map then
					raise (ExceptionDefn.Semantics_Error (p.Ast.port_pos,"Site '" ^ p.Ast.port_nme ^ "' is used multiple times"))
				else	
					iter ast_interface (StringMap.add p.Ast.port_nme (int_state_list, lnk_state, (p.Ast.port_pos)) map)
		| Ast.EMPTY_INTF -> StringMap.add "_" ([], Ast.FREE, Misc.no_pos) map
	in (*Adding default existential port*) iter ast_intf StringMap.empty

let eval_agent is_pattern env a ctxt =
	let (ag_name, ast_intf, pos_ag) = ((a.Ast.ag_nme), (a.Ast.ag_intf), (a.Ast.ag_pos)) in
	let name_id,env = 
		try (Environment.num_of_name ag_name env,env) with 
		| Not_found -> 
				if !Parameter.implicitSignature then 
					let env,id = Environment.declare_name ag_name pos_ag env in 
					(id,env)
				else 
					raise (ExceptionDefn.Semantics_Error (pos_ag,"Agent '" ^ ag_name ^ "' is not declared"))
	in
	let sign_opt =
		try Some (Environment.get_sig name_id env) with Not_found -> None in
	let sign,env =
		match sign_opt with
		| Some s -> (s,env)
		| None ->
			if !Parameter.implicitSignature then
				let sign = Signature.create name_id StringMap.empty in (sign,Environment.declare_sig sign pos_ag env)
			else
				raise	(ExceptionDefn.Semantics_Error (pos_ag,"Agent '" ^ ag_name ^ "' is not declared")) 
	in
	let port_map = eval_intf ast_intf in
	let (interface, ctxt, sign) =
		StringMap.fold
			(fun site_name (int_state_list, lnk_state, pos_site) (interface, ctxt, sign)->
				
				let site_id,sign =
					try (Signature.num_of_site site_name sign,sign)
					with
					| Not_found ->
						if !Parameter.implicitSignature then
							let sign = Signature.add_site site_name sign in
							(Signature.num_of_site site_name sign,sign)
						else
							let msg =
								"Eval.eval_agent: site '" ^	(site_name ^ ("' is not defined for agent '" ^ ag_name ^"'"))
							in 
							raise (ExceptionDefn.Semantics_Error (pos_site, msg))
				in
				let int_s,sign =
					match int_state_list with
					| [] -> (None,sign)
					| h::_ ->
						try
							Environment.check ag_name pos_ag site_name pos_site h env;
							let i = Environment.id_of_state ag_name site_name h env
							in 
							(Some i,sign)
						with
							| exn -> 
								if !Parameter.implicitSignature then
									let sign,i = Signature.add_internal_state h site_id sign in
									(Some i,sign)	 
								else raise exn
				in
				
				match lnk_state with
				| Ast.LNK_VALUE (n, pos) ->
						let lnk =
							(try Some (IntMap.find n ctxt.pairing)
							with | Not_found -> None)
						in
						(match lnk with
							| Some (Semi (b, j, _)) ->
									((IntMap.add site_id (int_s, Node.BND) interface),
										{ctxt	with
											pairing = IntMap.add n Closed ctxt.pairing;
											new_edges =
												Int2Map.add ((ctxt.curr_id), site_id) (b, j)
													ctxt.new_edges;
										},sign)
							| Some Closed ->
									let msg =
										"edge identifier " ^
										((string_of_int n) ^ " is used too many times")
									in raise (ExceptionDefn.Semantics_Error (pos, msg))
							| None ->
									((IntMap.add site_id (int_s, Node.BND) interface),
										{
											(ctxt)
											with
											pairing =
												IntMap.add n (Semi (ctxt.curr_id, site_id, pos))
													ctxt.pairing;
										},sign)
					)
				| Ast.LNK_SOME pos ->
						if is_pattern
						then ((IntMap.add site_id (int_s, Node.BND) interface), ctxt,sign)
						else
							(let msg = "illegal use of '_' in concrete graph definition"
								in raise (ExceptionDefn.Semantics_Error (pos, msg)))
				| Ast.LNK_ANY pos ->
						if is_pattern
						then ((IntMap.add site_id (int_s, Node.WLD) interface), ctxt, sign)
						else
							(let msg =
									"illegal use of wildcard '?' in concrete graph definition"
								in raise (ExceptionDefn.Semantics_Error (pos, msg)))
				| Ast.FREE ->
						((IntMap.add site_id (int_s, Node.FREE) interface), ctxt, sign)
				| Ast.LNK_TYPE ((ste_nm, pos_ste), (ag_nm, pos_ag)) ->
						if is_pattern then
							(let site_num =
									try Environment.id_of_site ag_nm ste_nm env
									with
									| Not_found -> raise (ExceptionDefn.Semantics_Error (pos_ste, "binding type is not compatible with agent's signature"))
								in
								let ag_num = 
									try Environment.num_of_name ag_nm env with
										| Not_found -> raise
												(ExceptionDefn.Semantics_Error (pos_ste,
														"Illegal binding type, agent "^ag_nm^" is not delcared"))
								in
								((IntMap.add site_id (int_s, Node.TYPE (site_num, ag_num)) interface),ctxt, sign)
						)
						else
							(let msg =
									"illegal use of binding type in concrete graph definition"
								in raise (ExceptionDefn.Semantics_Error (pos_ste, msg)))
			)
			port_map (IntMap.empty, ctxt, sign)
	in 
	let env = Environment.declare_sig sign pos_ag env 
	in
		(ctxt, (Mixture.create_agent name_id interface), env)

(* returns partial evaluation of rate expression and a boolean that is set *)
(* to true if partial evaluation is a constant function                    *)
let rec partial_eval_alg env ast =
	let bin_op ast ast' pos op op_str =
		let (f1, const1, dep1, lbl1) = partial_eval_alg env ast
		
		and (f2, const2, dep2, lbl2) = partial_eval_alg env ast' in
		let part_eval inst values t e =
			let v1 = f1 inst values t e and v2 = f2 inst values t e in op v1 v2 in
		let lbl = Printf.sprintf "(%s%s%s)" lbl1 op_str lbl2
		in (part_eval, (const1 && const2), (DepSet.union dep1 dep2), lbl)
	
	and un_op ast pos op op_str =
		let (f, const, dep, lbl) = partial_eval_alg env ast in
		let lbl = Printf.sprintf "%s(%s)" op_str lbl
		in
		((fun inst values t e -> let v = f inst values t e in op v), const,
			dep, lbl)
	in
	match ast with
	| INFINITY pos -> ((fun _ _ _ _ -> infinity), true, DepSet.empty, "inf")
	| FLOAT (f, pos) ->
			((fun _ _ _ _ -> f), true, DepSet.empty, (Printf.sprintf "%f" f))
	| OBS_VAR (lab, pos) -> (*maybe a kappa expr or an algebraic expression*)
			(try
				let i = Environment.num_of_kappa lab env
				in
				if Environment.is_rule i env
				then
					raise
						(ExceptionDefn.Semantics_Error (pos,
								lab ^ " is not a variable identifier"))
				else
					((fun f _ _ _ -> f i), false,
						(DepSet.singleton (Mods.KAPPA i)), ("'" ^ (lab ^ "'")))
			with
			| (*shifting obs_id because 0 is reserved for time dependencies*)
			Not_found -> (* lab is the label of an algebraic expression *)
					(try
						let i = Environment.num_of_alg lab env
						in
						((fun _ v _ _ -> v i), false,
							(DepSet.singleton (Mods.ALG i)), ("'" ^ (lab ^ "'")))
					with
					| Not_found ->
							raise
								(ExceptionDefn.Semantics_Error (pos,
										lab ^ " is not declared"))))
	| TIME_VAR pos ->
			((fun _ _ t _ -> t), false, (DepSet.singleton Mods.TIME), "t")
	| EVENT_VAR pos ->
			((fun _ _ _ e -> float_of_int e), false,
				(DepSet.singleton Mods.EVENT), "e")
	| DIV (ast, ast', pos) -> bin_op ast ast' pos (fun x y -> x /. y) "/"
	| SUM (ast, ast', pos) -> bin_op ast ast' pos (fun x y -> x +. y) "+"
	| MULT (ast, ast', pos) -> bin_op ast ast' pos (fun x y -> x *. y) "*"
	| MINUS (ast, ast', pos) -> bin_op ast ast' pos (fun x y -> x -. y) "-"
	| POW (ast, ast', pos) -> bin_op ast ast' pos (fun x y -> x ** y) "^"
	| MODULO (ast, ast', pos) -> bin_op ast ast' pos (fun x y -> float_of_int ((int_of_float x) mod (int_of_float y))) " modulo "
	| COSINUS (ast, pos) -> un_op ast pos cos "cos"
	| SINUS (ast, pos) -> un_op ast pos sin "sin"
	| EXP (ast, pos) -> un_op ast pos exp "e^"
	| SQRT (ast, pos) -> un_op ast pos sqrt "sqrt"
	| ABS (ast, pos) -> un_op ast pos (fun x -> float_of_int (abs (int_of_float x))) "abs"
	| LOG (ast, pos) -> un_op ast pos log "log"

let rec partial_eval_bool env ast =
	let bin_op_bool ast ast' pos op op_str =
		let (f1, const1, dep1, lbl1) = partial_eval_bool env ast
		
		and (f2, const2, dep2, lbl2) = partial_eval_bool env ast' in
		let part_eval inst values t e =
			let b1 = f1 inst values t e and b2 = f2 inst values t e in op b1 b2 in
		let lbl = Printf.sprintf "(%s %s %s)" lbl1 op_str lbl2
		in (part_eval, (const1 && const2), (DepSet.union dep1 dep2), lbl)
	
	and bin_op_alg ast ast' pos op op_str =
		let (f1, const1, dep1, lbl1) = partial_eval_alg env ast
		
	and (f2, const2, dep2, lbl2) = partial_eval_alg env ast' in
		let part_eval inst values t e =
			let v1 = f1 inst values t e and v2 = f2 inst values t e in op v1 v2 in
		let lbl = Printf.sprintf "(%s%s%s)" lbl1 op_str lbl2
		in (part_eval, (const1 && const2), (DepSet.union dep1 dep2), lbl)
	
	and un_op ast pos op op_str =
		let (f, const, dep, lbl) = partial_eval_bool env ast in
		let lbl = Printf.sprintf "%s(%s)" op_str lbl
		in
		((fun inst values t e -> let b = f inst values t e in op b), const,
			dep, lbl)
	in
	match ast with
		| TRUE pos -> ((fun _ _ _ _ -> true), true, DepSet.empty, "true")
		| FALSE pos -> ((fun _ _ _ _ -> false), true, DepSet.empty, "false")	
		| AND (ast, ast', pos) ->
				bin_op_bool ast ast' pos (fun b b' -> b && b') "and"
		| OR (ast, ast', pos) ->
				bin_op_bool ast ast' pos (fun b b' -> b || b') "or"
		| NOT (ast, pos) -> un_op ast pos (fun b -> not b) "not"
		| GREATER (ast, ast', pos) ->
				bin_op_alg ast ast' pos (fun v v' -> v > v') ">"
		| SMALLER (ast, ast', pos) ->
				bin_op_alg ast ast' pos (fun v v' -> v < v') "<"
		| EQUAL (ast, ast', pos) ->
				bin_op_alg ast ast' pos (fun v v' -> v = v') "="

let mixture_of_ast mix_id_opt is_pattern env ast_mix =
	let rec eval_mixture env ast_mix ctxt mixture =
		match ast_mix with
		| Ast.COMMA (a, ast_mix) ->
				let (ctxt, agent, env) = eval_agent is_pattern env a ctxt in
				let id = ctxt.curr_id and new_edges = ctxt.new_edges in
				let (ctxt, mixture, env) =
					eval_mixture env ast_mix
						{
							(ctxt)
							with
							curr_id = ctxt.curr_id + 1;
							new_edges = Int2Map.empty;
						} mixture
				in (ctxt, (Mixture.compose id agent mixture new_edges None), env)
		| Ast.EMPTY_MIX -> (ctxt, mixture, env)
		| Ast.DOT (radius, ast_ag, ast_mix) ->
				let (ctxt, agent, env) = eval_agent is_pattern env ast_ag ctxt in
				let id = ctxt.curr_id and new_edges = ctxt.new_edges
				
				and cstr =
					Some (Mixture.PREVIOUSLY_CONNECTED (radius, ctxt.curr_id + 1)) in
				let (ctxt, mixture, env) =
					eval_mixture env ast_mix
						{
							(ctxt)
							with
							curr_id = ctxt.curr_id + 1;
							new_edges = Int2Map.empty;
						} mixture
				in (ctxt, (Mixture.compose id agent mixture new_edges cstr), env)
		| Ast.PLUS (radius, ast_ag, ast_mix) ->
				let (ctxt, agent, env) = eval_agent is_pattern env ast_ag ctxt in
				let id = ctxt.curr_id and new_edges = ctxt.new_edges
				and cstr =
					Some (Mixture.PREVIOUSLY_DISCONNECTED (radius, ctxt.curr_id + 1)) in
				let (ctxt, mixture, env) =
					eval_mixture env ast_mix
						{
							(ctxt)
							with
							curr_id = ctxt.curr_id + 1;
							new_edges = Int2Map.empty;
						} mixture
				in (ctxt, (Mixture.compose id agent mixture new_edges cstr), env) 
	in
	
	let ctxt = { pairing = IntMap.empty; curr_id = 0; new_edges = Int2Map.empty; } in
	let (ctxt, mix, env) = eval_mixture env ast_mix ctxt (Mixture.empty mix_id_opt)
	in
	begin
		IntMap.iter (*checking that all edge identifiers are pairwise defined*)
		(fun n link ->
					match link with
					| Closed -> ()
					| Semi (_, _, pos) ->
							let msg =
								"edge identifier " ^ ((string_of_int n) ^ " is not paired")
							in raise (ExceptionDefn.Semantics_Error (pos, msg))
		)
		ctxt.pairing;
		let mix = Mixture.enum_alternate_anchors mix in (mix,env)
	end

let signature_of_ast s env =
	let (name, ast_intf, pos) =
		((s.Ast.ag_nme), (s.Ast.ag_intf), (s.Ast.ag_pos)) in
	let intf_map = eval_intf ast_intf in 
	let env,name_id = Environment.declare_name name pos env in
	(Signature.create name_id intf_map,env)

let rule_of_ast env (ast_rule_label, ast_rule) = (*TODO take into account no_poly*)
	let (env, lhs_id) =
		Environment.declare_var_kappa ~from_rule: true ast_rule_label.lbl_nme env in
	(* reserving an id for rule's lhs in the pattern table *)
	let env = Environment.declare_rule ast_rule_label.lbl_nme lhs_id env in
	let (k_def, dep) =
		let (k, const, dep, _) = partial_eval_alg env ast_rule.k_def
		in
		if const
		then ((CONST (k (fun i -> 0.0) (fun i -> 0.0) 0.0 0)), dep)
		else ((VAR k), dep)
	
	and (k_alt, dep_alt) =
		match ast_rule.k_un with
		| None -> (None, DepSet.empty)
		| Some ast ->
				let (rate, const, dep, _) = partial_eval_alg env ast
				in
				if const
				then
					((Some (CONST (rate (fun i -> 0.0) (fun i -> 0.0) 0.0 0))), dep)
				else ((Some (VAR rate)), dep)
	
	and lhs,env = mixture_of_ast (Some lhs_id) true env ast_rule.lhs
	in 
	let rhs,env = mixture_of_ast None true env ast_rule.rhs in
	let (script, balance,added,modif_sites,side_effect) = Dynamics.diff lhs rhs ast_rule_label.lbl_nme env
	
	and kappa_lhs = Mixture.to_kappa false lhs env
	
	and kappa_rhs = Mixture.to_kappa false rhs env in
	let ref_id =
		match ast_rule_label.lbl_ref with
		| None -> None
		| Some (ref, pos) ->
				(try Some (Environment.num_of_kappa ref env)
				with
				| Not_found ->
						raise
							(ExceptionDefn.Semantics_Error (pos, "undefined label " ^ ref))) in
	let r_id = Mixture.get_id lhs in
	let env =
		DepSet.fold
			(fun dep env -> Environment.add_dependencies dep (RULE r_id) env)
			(DepSet.union dep dep_alt) env
	in
	(env,
		{
			Dynamics.k_def = k_def;
			Dynamics.k_alt = k_alt;
			Dynamics.over_sampling = None;
			Dynamics.script = script;
			Dynamics.kappa = kappa_lhs ^ ("->" ^ kappa_rhs);
			Dynamics.balance = balance;
			Dynamics.constraints = Mixture.constraints lhs;
			Dynamics.refines = ref_id;
			Dynamics.lhs = lhs;
			Dynamics.rhs = rhs;
			Dynamics.r_id = r_id;
			Dynamics.added = List.fold_left (fun set i -> IntSet.add i set) IntSet.empty added ;
			Dynamics.side_effect = side_effect ; 
			Dynamics.modif_sites = modif_sites
		})

let variables_of_result env res =
	let is_pattern = true
	in
	List.fold_left
		(fun (env, mixtures, vars) var ->
					match var with
					| Ast.VAR_KAPPA (ast, label_pos) ->
							let (env, id) =
								Environment.declare_var_kappa (Some label_pos) env in
							let mix,env = mixture_of_ast (Some id) is_pattern env ast
							in (env, (mix :: mixtures), vars)
					| Ast.VAR_ALG (ast, label_pos) ->
							let (env, var_id) =
								Environment.declare_var_alg (Some label_pos) env in
							let (f, is_const, dep, lbl) = partial_eval_alg env ast in
							let v =
								if is_const
								then Dynamics.CONST (f (fun i -> 0.0) (fun i -> 0.0) 0.0 0)
								else Dynamics.VAR f
							in (env, mixtures, ((v, dep, var_id) :: vars)))
		(env, [], []) res.Ast.variables

let rules_of_result env res =
	let (env, l) =
		List.fold_left
			(fun (env, cont) (ast_rule_label, ast_rule) ->
						let (env, r) = rule_of_ast env (ast_rule_label, ast_rule)
						in (env, (r :: cont)))
			(env, []) res.Ast.rules
	in (env, (List.rev l))

let environment_of_result res =
	List.fold_left
		(fun env (sign, pos) ->
			let sign,env = signature_of_ast sign env in
				Environment.declare_sig sign pos env
		)
		Environment.empty res.Ast.signatures

let obs_of_result env res =
	List.fold_left
	(fun cont alg_expr ->
				let (obs, is_constant, dep, label) = partial_eval_alg env alg_expr
				in (dep, is_constant, obs, label) :: cont
	)
	[] res.observables
	

let effects_of_modif variables env ast =
	match ast with
	| INTRO (alg_expr, ast_mix, pos) ->
			let (x, is_constant, dep, str) = partial_eval_alg env alg_expr in
			(*let str_pert = Printf.sprintf "pert_%d" (Environment.next_pert_id env) in
			let (env, id) =
				Environment.declare_var_kappa (Some (str_pert,pos))	env (*declaring mix will allow us to copy injections easily*)
			in
			*)
			let m,env = mixture_of_ast None false env ast_mix in
			let v =
				if is_constant
				then Dynamics.CONST (x (fun _ -> 0.0) (fun i -> 0.0) 0.0 0)
				else Dynamics.VAR x in
			let str =
				Printf.sprintf "introduce %s * %s" str (Mixture.to_kappa false m env)
			in (variables, (Dynamics.INTRO (v, m)), str, env)
	| DELETE (alg_expr, ast_mix, pos) ->
			let (x, is_constant, dep, str) = partial_eval_alg env alg_expr in
			let str_pert = Printf.sprintf "pert_%d" (Environment.next_pert_id env) in
			let (env, id) =
				Environment.declare_var_kappa (Some (str_pert,pos)) env 
			in
			let m,env = mixture_of_ast (Some id) true env ast_mix in
			let v =
				if is_constant
				then Dynamics.CONST (x (fun _ -> 0.0) (fun i -> 0.0) 0.0 0)
				else Dynamics.VAR x in
			let str =
				Printf.sprintf "remove %s * %s" str (Mixture.to_kappa false m env)
			in ((m :: variables), (Dynamics.DELETE (v, m)), str, env)
	| UPDATE (nme, pos_rule, alg_expr, pos_pert) ->
			let i =
				(try Environment.num_of_rule nme env
				with
				| Not_found ->
						raise
							(ExceptionDefn.Semantics_Error (pos_rule,
									"Rule " ^ (nme ^ " is not declared"))))
			
			and (x, is_constant, dep, str) = partial_eval_alg env alg_expr in
			let v =
				if is_constant
				then Dynamics.CONST (x (fun _ -> 0.0) (fun i -> 0.0) 0.0 0)
				else Dynamics.VAR x in
			let str =
				Printf.sprintf "set rate of rule '%s' to %s"
					(Environment.rule_of_num i env) str
			in (variables, (Dynamics.UPDATE (i, v)), str, env)
	| SNAPSHOT pos -> (*when specializing snapshots to particular mixtures, add variables below*)
		let str = "snapshot state" in
		(variables, Dynamics.SNAPSHOT, str, env)
	| STOP pos ->
		let str = "interrupt simulation" in
		(variables, Dynamics.STOP, str, env)

let pert_of_result variables env res =
	let (variables, lpert, lrules, env) =
		List.fold_left
			(fun (variables, lpert, lrules, env) (bool_expr, modif_expr, pos, opt_post) ->				
				let (x, is_constant, dep, str_pre) = partial_eval_bool env bool_expr
				and (variables, effect, str_eff, env) =
					effects_of_modif variables env modif_expr in
				let bv =
					if is_constant
					then Dynamics.BCONST (x (fun _ -> 0.0) (fun _ -> 0.0) 0.0 0)
					else Dynamics.BVAR x in
				let str_pert,opt_abort =
					match opt_post with
					| None -> (Printf.sprintf "whenever %s, %s" str_pre str_eff,None)
					| Some bool_expr -> 
						let (x, is_constant, dep, str_abort) = partial_eval_bool env bool_expr in
						let bv = 
							if is_constant then Dynamics.BCONST (x (fun _ -> 0.0) (fun _ -> 0.0) 0.0 0)
							else Dynamics.BVAR x 
						in
						(Printf.sprintf "whenever %s, %s until %s" str_pre str_eff str_abort,Some (bv,dep,str_abort)) 
				in
				let env,p_id = Environment.declare_pert (str_pert,pos) env in
				let env,rule_opt =
					match effect with
					| Dynamics.INTRO (_,mix) ->
						begin
							let (env, id) =
								Environment.declare_var_kappa (Some (str_pert,pos)) env 
							in
							let lhs = Mixture.empty (Some id)
							and rhs = mix 
							in
							let (script,balance,added,modif_sites,side_effect) = Dynamics.diff lhs rhs (Some (str_pert,pos)) env
							and kappa_lhs = ""
							and kappa_rhs = Mixture.to_kappa false rhs env in
							let r_id = Mixture.get_id lhs in
							let str_pert = Printf.sprintf "pert_%d" p_id in
							let env = Environment.declare_rule (Some (str_pert,pos)) r_id env in
							let env =
								DepSet.fold
								(fun dep env -> Environment.add_dependencies dep (Mods.PERT p_id) env
								)
								dep env
							in 
							let rule_opt = Some
							{
								Dynamics.k_def = Dynamics.CONST 0.0;
								Dynamics.k_alt = None;
								Dynamics.over_sampling = None;
								Dynamics.script = script ;
								Dynamics.kappa = kappa_lhs ^ ("->" ^ kappa_rhs);
								Dynamics.balance = balance;
								Dynamics.constraints = Mixture.constraints lhs;
								Dynamics.refines = None;
								Dynamics.lhs = lhs;
								Dynamics.rhs = rhs;
								Dynamics.r_id = r_id;
								Dynamics.added = List.fold_left (fun set i -> IntSet.add i set) IntSet.empty added ;
								Dynamics.side_effect = side_effect ; 
								Dynamics.modif_sites = modif_sites
							}
							in
							(env,rule_opt)
						end
					| Dynamics.DELETE (_,mix) ->
						begin
							let lhs = mix
							and rhs = Mixture.empty None
							in
							let (script,balance,added,modif_sites,side_effect) = Dynamics.diff lhs rhs (Some (str_pert,pos)) env
							and kappa_lhs = Mixture.to_kappa false lhs env
							and kappa_rhs = "" in
							let r_id = Mixture.get_id lhs in
							let str_pert = Printf.sprintf "pert_%d" p_id in
							let env = Environment.declare_rule (Some (str_pert,pos)) r_id env in
							let env =
								DepSet.fold
								(fun dep env -> Environment.add_dependencies dep (Mods.PERT p_id) env
								)
								dep env
							in 
							let rule_opt = Some
							{
								Dynamics.k_def = Dynamics.CONST 0.0;
								Dynamics.k_alt = None;
								Dynamics.over_sampling = None;
								Dynamics.script = script ;
								Dynamics.kappa = kappa_lhs ^ ("->" ^ kappa_rhs);
								Dynamics.balance = balance;
								Dynamics.constraints = Mixture.constraints lhs;
								Dynamics.refines = None;
								Dynamics.lhs = lhs;
								Dynamics.rhs = rhs;
								Dynamics.r_id = r_id;
								Dynamics.added = List.fold_left (fun set i -> IntSet.add i set) IntSet.empty added ;
								Dynamics.side_effect = side_effect ; 
								Dynamics.modif_sites = modif_sites
							}
							in
							(env,rule_opt)
						end
					| Dynamics.UPDATE _ | Dynamics.SNAPSHOT | Dynamics.STOP -> 
						let env =
							DepSet.fold
							(fun dep env -> Environment.add_dependencies dep (Mods.PERT p_id) env
							)
							dep env
						in (env,None) 
				in
				let env = match rule_opt with None -> env | Some r -> Environment.bind_pert_rule p_id r.r_id env in
				let opt,env =
					match opt_abort with
					| None -> (None,env)
					| Some (bv,dep,str_post) -> 
						let env =
							DepSet.fold
							(fun dep_type env ->
								Environment.add_dependencies dep_type (Mods.ABORT p_id) env
							)
							dep env
						in
						(Some bv,env)
				in
				let pert = 
					{ Dynamics.precondition = bv;
						Dynamics.effect = effect;
						Dynamics.abort = opt;
						Dynamics.flag = str_pert;
					}
				in
				let lrules = match rule_opt with None -> lrules | Some r -> r::lrules
				in
				(variables, pert::lpert, lrules, env)
			)
			(variables, [], [], env) res.perturbations
		in 
		(variables, (List.rev lpert), (List.rev lrules), env)

let init_graph_of_result env res =
	List.fold_left
		(fun (sg,env) (n, ast, _) ->
					let cpt = ref 0
					and sg = ref sg
					and m,env = mixture_of_ast None false env ast
					in
					(* Cannot do Mixture.to_nodes env m once for all because of        *)
					(* references                                                      *)
					let sg = 
						(while !cpt < n do
							sg := Graph.SiteGraph.add_nodes !sg (Mixture.to_nodes env m);
							cpt := !cpt + 1 done;
						!sg)
					in
						(sg,env)
		)
		(Graph.SiteGraph.init !Parameter.defaultGraphSize,env) res.Ast.init
	
let initialize result =
	Debug.tag "Compiling..." ;

	let counter =	Counter.create 0.0 0 !Parameter.maxTimeValue !Parameter.maxEventValue in
	Debug.tag "\t agent signatures" ;
	let env = environment_of_result result in
	Debug.tag "Parsing initial conditions...";
	let sg,env = init_graph_of_result env result
	in
	Debug.tag "\t variable declarations";
	let (env, kappa_vars, alg_vars) = variables_of_result env result in
	Debug.tag "\t rules";
	let (env, rules) = rules_of_result env result in
	Debug.tag "\t plot instructions";
	let observables = obs_of_result env result in
	Debug.tag "\t perturbations" ;
	let (kappa_vars, pert, rule_pert, env) = pert_of_result kappa_vars env result
	in
	Debug.tag "Done";
	Debug.tag "Building initial simulation state...";
	let (state, env) =
		State.initialize sg rules kappa_vars alg_vars observables (pert,rule_pert) counter env
	in 
	(Debug.tag "Done"; (env, state, counter))