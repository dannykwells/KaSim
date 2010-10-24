open Mods
open Misc
open ExceptionDefn
open Dynamics
open Graph
open ValMap
open Random_tree

type implicit_state =
	{ graph : SiteGraph.t;
	 	injections : (component_injections option) array;
		rules : (int, rule) Hashtbl.t; 
		perturbations : perturbation IntMap.t;
		kappa_variables : (Mixture.t option) array;
		alg_variables : ((Dynamics.variable * float) option) array;
		observables : obs list; 
		influence_map : (int, (int IntMap.t list) IntMap.t) Hashtbl.t ;
		mutable activity_tree : Random_tree.tree; wake_up : Precondition.t
	}
and component_injections =
	(InjectionHeap.t option) array
and obs =
	{ label : string; expr : Dynamics.variable }


let kappa_of_id id state =
	try
		match state.kappa_variables.(id) with
		| None -> raise Not_found
		| Some mix -> mix
	with | Invalid_argument msg -> invalid_arg ("State.kappa_of_id: " ^ msg)

let rule_of_id id state = Hashtbl.find state.rules id

let alg_of_id id state =
	try
		match state.alg_variables.(id) with
		| None -> raise Not_found
		| Some var_f -> var_f
	with | Invalid_argument msg -> invalid_arg ("State.kappa_of_id: " ^ msg)

(**[instance_number mix_id state] returns the number of instances of mixture [mix_id] in implicit state [state]*)
let instance_number mix_id state =
	if mix_id = 0 then 1. (*empty mixture has 1 instance*)
	else
	match state.injections.(mix_id) with
	| None -> 0.
	| Some component_injections ->
			Array.fold_left
				(fun act opt ->
							match opt with
							| Some injs -> act *. (float_of_int (InjectionHeap.size injs))
							| None -> 0.)
				1. component_injections

(**[instances_of_square mix_id state] returns the list of full and valid embeddings (given as maps) of [mix_id] in [state]*)
let instances_of_square mix_id state =
	let extend (inj, codom) phi =
		try
			Some
			(Injection.fold
					(fun i j (inj, codom) ->
								if IntSet.mem j codom
								then raise False
								else ((IntMap.add i j inj), (IntSet.add j codom)))
					phi (inj, codom))
		with | False -> None
	in
	match state.injections.(mix_id) with
	| None -> invalid_arg "State.instances_of_square"
	| Some comp_injs ->
			Array.fold_left (*fold comp_injs*)
				(fun m opt ->
							match opt with
							| None -> invalid_arg "External.apply_effect"
							| Some injhp ->
									List.fold_left
										(fun cont (part_inj, part_codom) ->
													let ext_injhp =
														InjectionHeap.fold
															(fun _ phi cont' ->
																		let opt = extend (part_inj, part_codom) phi
																		in
																		match opt with
																		| None -> cont'
																		| Some (ext_inj, ext_codom) ->
																				(ext_inj, ext_codom) :: cont')
															injhp []
													in ext_injhp @ cont)
										[] m)
				[ (IntMap.empty, IntSet.empty) ] comp_injs

let rec value state var_id counter =
	let var_opt = try Some (alg_of_id var_id state) with | Not_found -> None
	in
	match var_opt with
	| None ->
			invalid_arg (Printf.sprintf "v[%d] is not a valid variable" var_id)
	| Some (var, _) ->
			(match var with
				| Dynamics.CONST f -> f
				| Dynamics.VAR v_fun ->
						let act_of_id id = instance_number id state
						
						and v_of_var id = value state id counter
						in
						v_fun act_of_id v_of_var (Counter.time counter)
							(Counter.event counter))

(**[eval_activity rule state] returns the evaluation of the activity --not divided by automorphisms-- of rule [rule] in implicit state [state]*)
let eval_activity rule state counter =
	match rule.over_sampling with
	| Some k -> k
	| None ->
			let mix_id = Mixture.get_id rule.lhs
			and kin = rule.k_def
			in
			(match kin with
				| Dynamics.CONST f -> f *. (instance_number mix_id state)
				| Dynamics.VAR k_fun ->
						let act_of_id id = instance_number id state
						
						and v_of_var id = value state id counter in
						let k =
							k_fun act_of_id v_of_var (Counter.time counter)
								(Counter.event counter)
						in
						if k = infinity
						then
							invalid_arg
								(Printf.sprintf
										"Kinetic rate of rule '%s' has become undefined"
										rule.kappa)
						else k *. (instance_number mix_id state))

let pert_of_id state id = IntMap.find id state.perturbations

let update_activity state var_id counter env =
	if not (Environment.is_rule var_id env) then ()
	else
	let rule = rule_of_id var_id state in
	let alpha = eval_activity rule state counter
	in
	try
		Random_tree.add var_id alpha state.activity_tree
	with Invalid_argument msg -> invalid_arg ("State.update_activity: "^msg)

(* compute complete embedding of mix into sg at given root --for           *)
(* initialization phase                                                    *)
let generate_embeddings sg u_i mix comp_injs =
	let node_i =
		try SiteGraph.node_of_id sg u_i
		with
		| Invalid_argument msg ->
				invalid_arg ("Matching.generate_embeddings: " ^ msg) in
	let name = Node.name node_i and mix_id = Mixture.get_id mix in
	let rec iter cc_id sg comp_injs =
		if cc_id = (Mixture.arity mix)
		then (sg, comp_injs)
		else
			(let id_opt = (*pick one representative for cc_id*)
					try Some (IntSet.choose (Mixture.ids_of_name (name, cc_id) mix))
					with | Not_found -> None
				in
				match id_opt with
				| None -> iter (cc_id + 1) sg comp_injs
				| Some id_root ->
						let opt_inj =
							Matching.component
								(Injection.empty (Mixture.size_of_cc cc_id mix) (mix_id,cc_id)) id_root
								(sg, u_i) mix
						in
						(match opt_inj with
							| None -> iter (cc_id + 1) sg comp_injs
							| (*no match for cc_id rooted at u_i*)
							Some (injection, port_map) ->
							(* port_map: u_i -> [(p_k,0/1);...] if port k of node i is   *)
							(* int/lnk-tested by map                                     *)
									let opt =
										(try comp_injs.(cc_id)
										with
										| Invalid_argument msg ->
												invalid_arg ("State.generate_embeddings: " ^ msg)) in
									let cc_id_injections =
										(match opt with
											| Some injections -> injections
											| None ->
													InjectionHeap.create
														!Parameter.defaultInjectionHeapSize) in
									let cc_id_injections =
										InjectionHeap.alloc injection cc_id_injections
									in
									(comp_injs.(cc_id) <- Some cc_id_injections;
										let sg =
											SiteGraph.add_lift sg injection port_map
										in iter (cc_id + 1) sg comp_injs)))
	in iter 0 sg comp_injs

(**[initialize_embeddings state mix_list] *)
let initialize_embeddings state mix_list =
	SiteGraph.fold
	(fun i node_i state ->
		List.fold_left
		(fun state mix ->
			let injs = state.injections in
			let opt = injs.(Mixture.get_id mix) in
			let comp_injs =
				match opt with
				| None -> Array.create (Mixture.arity mix) None
				| Some comp_injs -> comp_injs in
			(* complement the embeddings of mix in sg using node i  as anchor for matching *)
			let (sg, comp_injs) =
				generate_embeddings state.graph i mix comp_injs
			in
			(* adding variables.(mix_id) = mix to variables array *)
			state.kappa_variables.(Mixture.get_id mix) <- Some mix;
			injs.(Mixture.get_id mix) <- Some comp_injs;
			(* adding injections.(mix_id) = injs(mix) to injections array*)
			{state with graph = sg}
		)
		state mix_list
	)
	state.graph state

let build_influence_map rules patterns env =
	let add_influence im i j glueings = 
		let map = try Hashtbl.find im i with Not_found -> IntMap.empty in
		Hashtbl.replace im i (IntMap.add j glueings map)
	in
	let influence_map = Hashtbl.create (Hashtbl.length rules) in
	Hashtbl.iter
	(fun i r -> 
		match r.refines with
			| Some _ -> () 
			| None ->
				Array.iteri 
				(fun j opt ->
					match opt with
						| None -> () (*empty pattern*)
						| Some mix ->
							let glueings = Dynamics.enable r mix env in
							match glueings with
								| [] -> ()
								| _ ->
							 		add_influence influence_map i j glueings	
				) patterns
	) rules ;
	influence_map

let initialize sg rules kappa_vars alg_vars obs (pert,rule_pert) counter env =
	let dim_pure_rule = (List.length rules)
	in
	let dim_rule = dim_pure_rule + (List.length rule_pert) 
	and dim_kappa = (List.length kappa_vars) + 1
	and dim_var = List.length alg_vars 
	in
	
	let injection_table = Array.make (dim_rule + dim_kappa) None
	and kappa_var_table = Array.make (dim_rule + dim_kappa) None (*list of rule left hand sides and kappa variables*)
	and alg_table = Array.make dim_var None (*list of algebraic values*)
	and rule_table = Hashtbl.create dim_rule (*list of rules*)
	and perturbation_table = IntMap.empty (*list of perturbations*)
	and wake_up_table = Precondition.empty () (*wake up table for side effects*)
	and influence_table = Hashtbl.create dim_rule (*influence map*)
	in
	
	let kappa_variables =
		(* forming kappa variable list by merging rule (and perturbation) lhs with kappa variables *)
		List.fold_left
		(fun patterns r ->
			let i = r.r_id
			in
				let patterns = 
					if Mixture.is_empty r.lhs then patterns (*nothing to track if left hand side is empty*)
					else r.lhs :: patterns
				in
				(Hashtbl.replace rule_table i r; patterns)
		)
		kappa_vars (rule_pert@rules) 
	in
	let state_init =
		{
			graph = sg;
			injections = injection_table ;
			rules = rule_table ;
			perturbations =
				begin
					let perturbation_table, _ =
						List.fold_left
						(fun (pt, i) pert -> ((IntMap.add i pert pt), (i + 1))
						)
						(perturbation_table, 0) pert
					in 
					perturbation_table
				end ;
			kappa_variables = kappa_var_table;
			alg_variables = alg_table;
			observables =
				begin
					List.fold_left
					(fun cont (dep, const, plot_v, lbl) ->
								if const
								then
									{
										expr = CONST (plot_v (fun i -> 0.0) (fun i -> 0.0) 0.0 0);
										label = Misc.replace_space lbl;
									} :: cont
								else { expr = VAR plot_v; label = Misc.replace_space lbl; } :: cont)
					[] obs
				end ;
			activity_tree = Random_tree.create dim_pure_rule ; (*put only true rules in the activity tree*)
			influence_map = influence_table ;
			wake_up = wake_up_table;
		}
	in
	
	if !Parameter.debugModeOn then Debug.tag "\t * Initializing injections...";
	let state = (*initializing injections*)
		initialize_embeddings state_init kappa_variables
	in
	
	if !Parameter.debugModeOn then Debug.tag "\t * Initializing variables...";
	let env =
		List.fold_left
		(fun env (v, deps, var_id) ->
			try
				let env =
					DepSet.fold
						(fun dep env ->
									Environment.add_dependencies dep (Mods.ALG var_id) env
						)
						deps env
				in (state.alg_variables.(var_id) <- Some (v, 0.0); env)
			with
			| Invalid_argument msg ->
					invalid_arg ("State.initialize: " ^ msg)
		)
		env alg_vars
	in
	
	if !Parameter.debugModeOn then Debug.tag	"\t * Initializing wake up map for side effects...";
	let state =
		(* initializing preconditions on pattern list for wake up map *)
		List.fold_left
		(fun state mix ->
					{state with wake_up = Precondition.add mix state.wake_up}
		)
		state kappa_variables
	in
	
	if !Parameter.debugModeOn then Debug.tag "\t * Initializing activity tree...";
	let act_tree = (*initializing activity tree*)
		Hashtbl.fold
		(fun id rule act_tree ->
			(*rule could be a perturbation*)
			if not (Environment.is_rule id env) then act_tree
			else
				let alpha_rule = eval_activity rule state counter
				in (Random_tree.add id alpha_rule act_tree; act_tree)
		)
			state.rules state.activity_tree	
	in
	if !Parameter.debugModeOn then Debug.tag "\t * Computing influence map...";
	let im = build_influence_map state.rules state.kappa_variables env 
	in
	({state with activity_tree = act_tree; influence_map = im}, env)

(* Returns an array {|inj0;...;inj_k|] where arity(r)=k containing one     *)
(* random injection per connected component of lhs(r)                      *)
let select_injection state mix =
	if Mixture.is_empty mix then Array.create 0 None
	else
	let mix_id = Mixture.get_id mix in
	let arity = Mixture.arity mix in
	let opt =
		try state.injections.(mix_id)
		with
		| Invalid_argument msg -> invalid_arg ("State.select_injection: " ^ msg)
	in
	match opt with
	| None ->
			invalid_arg
				("State.select_injection: variable " ^
					((string_of_int mix_id) ^
						" has no instance but a positive activity"))
	| Some comp_injs ->
			let embedding = Array.create arity None in
			(* let embedding = get_array arity in *)
			let _ =
				Array.fold_left
					(fun (i, total_cod) injheap_opt ->
								match injheap_opt with
								| None -> invalid_arg "State.select_injection"
								| Some injheap ->
										(try
											let inj = InjectionHeap.random injheap in
											let total_cod =
												try Injection.codomain inj total_cod
												with | Injection.Clashing -> raise Null_event
											in (embedding.(i) <- Some inj; ((i + 1), total_cod))
										with
										| Invalid_argument msg ->
												invalid_arg ("State.select_injection: " ^ msg)))
					(0, IntSet.empty) comp_injs
			in embedding

(* Draw a rule at random in the state according to its activity *)
let draw_rule state counter =
	try
		let lhs_id = Random_tree.random state.activity_tree in
		(* Activity.random_val state.activity_tree *)
		let r =
			try rule_of_id lhs_id state
			with | Not_found -> invalid_arg "State.draw_rule" in
		let alpha' =
			try Random_tree.find lhs_id state.activity_tree
			with
			| Not_found ->
					invalid_arg
						(Printf.sprintf "State.drw_rule: %d is not a valid rule indices"
								lhs_id)
		and alpha =
			try eval_activity r state counter
			with | Not_found -> invalid_arg "State.draw_rule"
		in
		(if alpha > alpha'
			then invalid_arg "State.draw_rule: activity invariant violation"
			else ();
			let rd = Random.float 1.0
			in
			if rd > (alpha /. alpha')
			then
				(Random_tree.add lhs_id alpha state.activity_tree;
					raise Null_event)
			else
				(let embedding = select_injection state r.lhs
					in ((Some (r, embedding)), state)))
	with | Not_found -> raise Deadlock

let wake_up state modif_type modifs wake_up_map =
	Int2Set.iter
		(fun (node_id, site_id) ->
					let opt =
						try Some (SiteGraph.node_of_id state.graph node_id)
						with | exn -> None
					in
					match opt with
					| None -> ()
					| Some node ->
							let old_candidates =
								(try Hashtbl.find wake_up_map node_id
								with | Not_found -> Int2Set.empty)
							in
							(* {(mix_id,cc_id),...} *)
							(match modif_type with
								| 0 -> (*internal state modif*)
										let new_candidates =
											Precondition.find_all (Node.name node) site_id
												(Node.internal_state (node, site_id)) None false
												state.wake_up
										in
										(* adding pairs (mix_id,cc_id) to the potential new    *)
										(* matches to be tried at anchor node_id               *)
										Hashtbl.replace wake_up_map node_id
											(Int2Set.union old_candidates new_candidates)
								| 1 -> (*link state modification*)
										let is_free = not (Node.is_bound (node, site_id)) in
										let new_candidates =
											if is_free
											then
												Precondition.find_all (Node.name node) site_id None
													None is_free state.wake_up
											else
												(let link_opt =
														match Node.follow (node, site_id) with
														| None -> invalid_arg "State.wake_up"
														| Some (node', site_id') ->
																Some (Node.name node', site_id')
													in
													Precondition.find_all (Node.name node) site_id
														None link_opt is_free state.wake_up)
										in
										Hashtbl.replace wake_up_map node_id
											(Int2Set.union old_candidates new_candidates)
								| _ -> (*intro*)
										let is_free = not (Node.is_bound (node, site_id)) in
										let new_candidates =
											let link_opt =
												(match Node.follow (node, site_id) with
													| None -> None
													| Some (node', site_id') ->
															Some (Node.name node', site_id'))
											in
											Precondition.find_all (Node.name node) site_id
												(Node.internal_state (node, site_id)) link_opt
												is_free state.wake_up
										in
										Hashtbl.replace wake_up_map node_id
											(Int2Set.union old_candidates new_candidates)))
		modifs

let rec update_dep state dep_in pert_ids counter env =
	let depset = Environment.get_dependencies dep_in env in
	if DepSet.is_empty depset	then (env,pert_ids)
	else
		let env,depset',pert_ids =
			if !Parameter.debugModeOn then if !Parameter.debugModeOn then Debug.tag (Printf.sprintf "Updating dependencies %s" (string_of_set Mods.string_of_dep DepSet.fold depset));
			DepSet.fold
				(fun dep (env,cont,pert_ids) ->
							match dep with
							| Mods.ALG v_id ->
									let depset' =
										Environment.get_dependencies (Mods.ALG v_id) env
									in
									(*if !Parameter.debugModeOn then Debug.tag (Printf.sprintf "Variable %d is changed, updating %s" v_id (Misc.string_of_set Mods.string_of_dep DepSet.fold depset')) ;*)
									(env,DepSet.union depset' cont,pert_ids)
							| Mods.RULE r_id ->
									(update_activity state r_id counter env;
										let depset' =
											Environment.get_dependencies (Mods.RULE r_id) env
										in
										if !Parameter.debugModeOn then if !Parameter.debugModeOn then Debug.tag (Printf.sprintf "Rule %d is changed, updating %s" r_id (Misc.string_of_set Mods.string_of_dep DepSet.fold depset')) ;
										(env,DepSet.union depset' cont,pert_ids)
									)
							| Mods.PERT p_id -> 
								if IntMap.mem p_id state.perturbations then (env,cont,IntSet.add p_id pert_ids)
								else 
									(Environment.remove_dependencies dep_in (Mods.PERT p_id) env,cont,pert_ids)
							| Mods.ABORT p_id ->
								if IntMap.mem p_id state.perturbations then (env,cont,IntSet.add p_id pert_ids)
								else 
									(Environment.remove_dependencies dep_in (Mods.PERT p_id) env,cont,pert_ids)
							| Mods.KAPPA i ->
									invalid_arg
										(Printf.sprintf
												"State.update_dep: kappa variable %d should have no dependency"
												i)
							| Mods.EVENT | Mods.TIME ->
									invalid_arg
										"State.update_dep: time or event should have no dependency"
				)
				depset (env,DepSet.empty,pert_ids)
		in 
		DepSet.fold
		(fun dep (env,pert_ids) -> update_dep state dep pert_ids counter env
		) 
		depset' (env,pert_ids)

let enabled r state = 
	let r_id = Mixture.get_id r.lhs in 
	try Hashtbl.find state.influence_map r_id with Not_found -> IntMap.empty
	
let positive_update state r (phi,psi) (side_modifs,pert_intro) counter env = (*pert_intro is temporary*)
	(*let t_upd = Profiling.start_chrono () in*)
	
	(* sub function find_new_inj *)
	let find_new_inj state var_id mix cc_id node_id root pert_ids already_done_map env =
		if !Parameter.debugModeOn then if !Parameter.debugModeOn then Debug.tag (Printf.sprintf "Trying to embed Var[%d] using root %d at node %d" var_id root node_id);
		let root_node_set =	try IntMap.find var_id already_done_map
			with Not_found -> Int2Set.empty in
		let opt =
			try state.injections.(var_id)
			with Invalid_argument msg -> invalid_arg ("State.positive_update: " ^ msg) 
		in
		let comp_injs =
			match opt with
			| None -> invalid_arg "State.positive_update"
			| Some injs -> injs in
		let opt =
			try comp_injs.(cc_id)
			with
			| Invalid_argument msg ->
					invalid_arg ("State.positive_update: " ^ msg) in
		let cc_id_injections =
			match opt with
			| Some injections -> injections
			| None ->	InjectionHeap.create !Parameter.defaultInjectionHeapSize 
		in
		let reuse_embedding =
			match InjectionHeap.next_alloc cc_id_injections with
			| Some phi ->
					(if !Parameter.debugModeOn then if !Parameter.debugModeOn then Debug.tag (Printf.sprintf "reusing injection: %s" (Injection.to_string phi));
					Injection.flush phi (var_id,cc_id))
			| None -> Injection.empty (Mixture.size_of_cc cc_id mix) (var_id,cc_id)
		in			
		let opt_emb = Matching.component ~already_done:root_node_set reuse_embedding root (state.graph, node_id) mix in 
		match opt_emb	with
		| None ->
				(if !Parameter.debugModeOn then if !Parameter.debugModeOn then Debug.tag "No new embedding was found";
				(env,state, pert_ids, already_done_map)
				)
		| Some (embedding, port_map) ->
				if !Parameter.debugModeOn then if !Parameter.debugModeOn then Debug.tag	(Printf.sprintf "New embedding: %s" (Injection.to_string embedding)) ;
				let cc_id_injections = InjectionHeap.alloc embedding cc_id_injections in
				comp_injs.(cc_id) <- Some cc_id_injections ;
				let graph =	SiteGraph.add_lift state.graph embedding port_map
				in
				let state = {state with graph = graph}
				in
				begin
					update_activity state var_id counter env;
					let env,pert_ids = 
						update_dep state (Mods.KAPPA var_id) pert_ids counter env
					in
					let already_done_map' = IntMap.add var_id	(Int2Set.add (root, node_id) root_node_set) already_done_map
					in
					(env,state, pert_ids, already_done_map')
				end
	in
	(* end of sub function find_new_inj definition *)
	
	let vars_to_wake_up = enabled r state in
	let env,state,pert_ids,already_done_map =
		IntMap.fold 
		(fun var_id map_list (env, state,pert_ids,already_done_map) ->
			if !Parameter.debugModeOn then if !Parameter.debugModeOn then Debug.tag (Printf.sprintf "Influence map tells me I should look for new injections of var[%d]" var_id) ;
			List.fold_left 
			(fun (env,state,pert_ids,already_done_map) glue ->
				let opt = IntMap.root glue in
				match opt with
					| None -> invalid_arg "State.positive_update"
					| Some (root_mix,root_rhs) ->
						let node_id = 
							if IntSet.mem root_rhs r.added then 
								(try IntMap.find root_rhs psi with Not_found -> invalid_arg "State.positive_update 1")
							else
								let cc_id = Mixture.component_of_id root_rhs r.lhs in
								let opt = phi.(cc_id) in
								match opt with
									| None -> invalid_arg "State.positive_update 2"
									| Some inj -> 
										try Injection.find root_rhs inj 
										with 
											| Not_found -> 
												(if !Parameter.debugModeOn then if !Parameter.debugModeOn then Debug.tag (Printf.sprintf "I was looking for the image of agent %d by embedding %s" 
												root_rhs (Injection.to_string inj)) ;
												if !Parameter.debugModeOn then if !Parameter.debugModeOn then Debug.tag (Printf.sprintf "Glueing was %s" (string_of_map string_of_int string_of_int IntMap.fold glue)) ; 
												invalid_arg "State.positive_update 3")
						in
						let mix =
							let opt =
								try state.kappa_variables.(var_id)
								with
								| Invalid_argument msg ->
										invalid_arg ("State.positive_update: " ^ msg)
							in
							match opt with
							| Some mix -> mix
							| None -> invalid_arg "State.positive_update" 
						in
						let cc_id = Mixture.component_of_id root_mix mix in
						(*already_done_map is empty because glueings are guaranteed to be difference by construction*)
						let env,state,pert_ids,already_done_map = 
							find_new_inj state var_id mix cc_id node_id root_mix pert_ids already_done_map env
						in
						(env,state, pert_ids, already_done_map)
			) (env,state, pert_ids, already_done_map) map_list
		) vars_to_wake_up (env, state, IntSet.empty, IntMap.empty)  
	in
	
	if not r.Dynamics.side_effect then 
		((*Profiling.add_chrono "Upd+" Parameter.profiling t_upd ;*)			
		(env,state,pert_ids))
	else
	(*Handling side effects*)
	let wu_map = Hashtbl.create !Parameter.defaultExtArraySize
	in
		wake_up state 1 side_modifs wu_map;
		wake_up state 2 pert_intro wu_map ;
		let (env,state, pert_ids, _) =
		Hashtbl.fold
			(fun node_id candidates (env,state, pert_ids, already_done_map) ->
				if !Parameter.debugModeOn then Debug.tag (Printf.sprintf "Side effect on node %d forces me to look for new embedding..." node_id);
				let node = SiteGraph.node_of_id state.graph node_id
				in
				Int2Set.fold
				(fun (var_id, cc_id) (env, state, pert_ids, already_done_map) ->
					let mix =
						let opt =
							try state.kappa_variables.(var_id)
							with
							| Invalid_argument msg ->
									invalid_arg ("State.positive_update: " ^ msg)
						in
						match opt with
						| Some mix -> mix
						| None -> invalid_arg "State.positive_update" 
					in
					let possible_roots =
						Mixture.ids_of_name ((Node.name node), cc_id) mix
					in
						IntSet.fold 
						(fun root (env,state, pert_ids, already_done_map) ->
							find_new_inj state var_id mix cc_id node_id root pert_ids already_done_map env
						) possible_roots (env,state, pert_ids, already_done_map)
				) candidates (env, state, pert_ids, already_done_map)
		)	wu_map (env, state, pert_ids, already_done_map)
	in
	((*Profiling.add_chrono "Upd+" Parameter.profiling t_upd ;*)				
	(env,state,pert_ids)
	)

(* Negative update *)
let negative_upd state (u, i) int_lnk counter env =
	if !Parameter.debugModeOn then Debug.tag (Printf.sprintf "Negative update as indicated by %s#%d site %d" 
	(Environment.name (Node.name u) env) (Node.get_address u) i);
		
	(* sub-function that removes all injections pointed by lifts --if they *)
	(* still exist                                                         *)
	let remove_injs state liftset pert_ids env =
		let injections = state.injections
		in
		LiftSet.fold
			(fun phi (env,pert_ids) ->
				let (mix_id, cc_id, inj_id) =
					let (m,c) = Injection.get_coordinate phi
					and i = try Injection.get_address phi with Not_found -> invalid_arg "State.negative_update"
					in
					(m,c,i)
				in
				let comp_injs_opt =
					try injections.(mix_id)
					with
					| Invalid_argument msg ->
							invalid_arg ("State.negative_upd: " ^ msg)
				in
				match comp_injs_opt with
				| None ->
						invalid_arg
							"State.negative_upd: rule was applied with no injection"
				| Some comp_injs ->
						let opt_inj_cc_id =
							(try comp_injs.(cc_id)
							with
							| Invalid_argument msg ->
									invalid_arg ("State.negative_upd: " ^ msg)) in
						let injs_cc_id =
							match opt_inj_cc_id with
								| None ->
										invalid_arg
											"State.negative_upd: rule was applied when a cc had no injection"
								| Some injs_cc_id -> injs_cc_id
						in
						let _ (*injs_cc_id*) =
						begin
							let mix = kappa_of_id mix_id state
							in
							Injection.fold
							(fun i j _ ->
								let a_i = Mixture.agent_of_id i mix
								and u_j =	SiteGraph.node_of_id state.graph j
								in
								Mixture.fold_interface
								(fun site_id (int_opt, lnk_opt) _ ->
									let (_ : unit) =
										match int_opt with
										| None -> ()
										| Some _ ->
												let (lifts, _) = Node.get_lifts u_j site_id
												in
												LiftSet.remove lifts phi
									in
									match lnk_opt with
									| Node.WLD -> ()
									| Node.BND | Node.TYPE _ |	Node.FREE ->
										let (_, lifts) = Node.get_lifts u_j	site_id
										in
										LiftSet.remove lifts phi
									) a_i ()
								) phi () ;
								InjectionHeap.remove inj_id injs_cc_id
						end
						in
						(* comp_injs.(cc_id) <- Some injs_cc_id; *)
						(* not necessary because comp_injs.(cc_id) has been    *)
						(* modified by side effect                             *)
						update_dep state (RULE mix_id) pert_ids counter env
					)
					liftset (env,pert_ids) 
	in
	(*end sub function*)
	let (liftset_int, liftset_lnk) = Node.get_lifts u i
	in
	let env,pert_ids = 
		match int_lnk with
			| 0 -> remove_injs state liftset_int IntSet.empty env
			| 1 -> remove_injs state liftset_lnk IntSet.empty env
			| _ -> 
				(let env,pert_ids = remove_injs state liftset_lnk IntSet.empty env in 
					remove_injs state liftset_int pert_ids env)
	in
	(env,pert_ids)

(* bind allow for looping bond *)
let bind state (u, i) (v, j) modifs pert_ids counter env =
	let intf_u = Node.interface u and intf_v = Node.interface v in
	(* no side effect *)
	let (int_u_i, ptr_u_i) = intf_u.(i).Node.status
	
	and (int_v_j, ptr_v_j) = intf_v.(j).Node.status in
	let env,modifs,pert_ids = (*checking for side effects*)
		match ptr_u_i with
		| Node.FPtr _ -> invalid_arg "State.bind"
		| Node.Null -> (env,modifs,pert_ids)
		| Node.Ptr (u', i') ->
				begin
					Node.set_ptr (u', i') Node.Null;
					let env,pert_ids = negative_upd state (u', i') 1 counter env in
					try (env,Int2Set.add ((Node.get_address u'), i') modifs, pert_ids)	
					with  Not_found -> invalid_arg "State.bind: Not_found"
				end 
	in
	(* when node is not allocated *)
	let env,modifs,pert_ids =
		match ptr_v_j with
		| Node.FPtr _ -> invalid_arg "State.bind"
		| Node.Null -> (env,modifs,pert_ids)
		| Node.Ptr (v', j') ->
			begin
				Node.set_ptr (v', j') Node.Null;
				let env,pert_ids' = negative_upd state (v', j') 1 counter env in
				try 
					(env,Int2Set.add ((Node.get_address v'), j') modifs, IntSet.union pert_ids pert_ids')
				with Not_found -> invalid_arg "State.bind: not found"
			end
	in
	intf_u.(i) <-	{ (intf_u.(i)) with Node.status = (int_u_i, Node.Ptr (v, j)) };
	let env,pert_ids' = negative_upd state (u, i) 1 counter env in
	let pert_ids = IntSet.union pert_ids pert_ids' in 
	intf_v.(j) <- { (intf_v.(j)) with Node.status = (int_v_j, Node.Ptr (u, i)) };
	let env,pert_ids' = negative_upd state (v, j) 1 counter env in
	let pert_ids = IntSet.union pert_ids pert_ids' in
	(env,modifs,pert_ids)

let break state (u, i) modifs pert_ids counter env =
	let intf_u = Node.interface u and warn = 0 in
	let (int_u_i, ptr_u_i) = intf_u.(i).Node.status
	in
	match ptr_u_i with
	| Node.FPtr _ -> invalid_arg "State.break"
	| Node.Ptr (v, j) ->
			let intf_v = Node.interface v in
			let (int_v_j, ptr_v_j) = intf_v.(j).Node.status
			in
			(intf_u.(i) <-
				{ (intf_u.(i)) with Node.status = (int_u_i, Node.Null); };
				let env,pert_ids = negative_upd state (u, i) 1 counter env in
				intf_v.(j) <-
				{ (intf_v.(j)) with Node.status = (int_v_j, Node.Null); };
				let env,pert_ids' = negative_upd state (v, j) 1 counter env in
				let pert_ids = IntSet.union pert_ids pert_ids' in
				(warn,env,(Int2Set.add ((Node.get_address v), j) modifs),pert_ids)
			)
	| Node.Null -> ((warn + 1),env, modifs,pert_ids)

let modify state (u, i) s pert_ids counter env =
	let intf_u = Node.interface u and warn = 0 in
	let (int_u_i, lnk_u_i) = intf_u.(i).Node.status
	in
	match int_u_i with
	| Some j ->
			(intf_u.(i) <-
				{ (intf_u.(i)) with Node.status = ((Some s), lnk_u_i); };
				let warn = if s = j then warn + 1 else warn
				in
				(* if s=j then null event *)
				let env,pert_ids = if s <> j then negative_upd state (u, i) 0 counter env else (env,pert_ids) in
				(warn,env,pert_ids)
			)
	| None ->
			invalid_arg
				("State.modify: node " ^
					((Environment.name (Node.name u) env)^" has no internal state to modify"))

let delete state u modifs pert_ids counter env =
	Node.fold_status
	(fun i (_, lnk) (env,modifs,pert_ids) ->
		let env,pert_ids' = negative_upd state (u, i) 2 counter env in
		let pert_ids = IntSet.union pert_ids pert_ids' in
			(* delete injection pointed by both lnk and int-lifts *)
			match lnk with
			| Node.FPtr _ -> invalid_arg "State.delete"
			| Node.Null -> (env,modifs,pert_ids)
			| Node.Ptr (v, j) ->
					Node.set_ptr (v, j) Node.Null;
					let env,pert_ids' = negative_upd state (v, j) 1 counter env in
					let pert_ids = IntSet.union pert_ids pert_ids' in
					(env,Int2Set.add ((Node.get_address v), j) modifs,pert_ids)
	)
	u (env,modifs,pert_ids)

let apply state r embedding counter env =
	let mix = r.lhs in
	let (_ : unit) =
		IntMap.iter
			(fun id constr ->
						(if !Parameter.debugModeOn then Debug.tag "Checking constraints";
							match constr with
							| Mixture.PREVIOUSLY_DISCONNECTED (radius, id') ->
									let dmap =
										SiteGraph.neighborhood
											~interrupt_with: (IntSet.singleton id') state.graph id
											radius
									in
									if IntMap.mem id' dmap
									then raise Null_event
									else
										if !Parameter.debugModeOn then Debug.tag
											(let radius =
													if radius = (- 1) then "inf" else string_of_int radius
												in
												Printf.sprintf
													"%d and %d are not connected in radius %s (ok)" id
													id' radius)
							| Mixture.PREVIOUSLY_CONNECTED (radius, id') ->
									let dmap =
										SiteGraph.neighborhood
											~interrupt_with: (IntSet.singleton id') state.graph id
											radius
									in if IntMap.mem id' dmap then () else raise Null_event))
			r.constraints in
	let app state control embedding fresh_map (id, i) =
		try
			match id with
			| FRESH j ->
					(if !Parameter.debugModeOn then Debug.tag
							(Printf.sprintf "Looking for agent %d in graph"
									(IntMap.find j fresh_map));
						(((SiteGraph.node_of_id state.graph (IntMap.find j fresh_map)), i),
							control))
			| KEPT j ->
					let cc_j = Mixture.component_of_id j mix in
					let psi_opt =
						(try embedding.(cc_j)
						with
						| Invalid_argument msg -> invalid_arg ("State.apply: " ^ msg)) in
					let psi =
						(match psi_opt with
							| Some emb -> emb
							| None -> invalid_arg "State.apply")
					in
					(try
						let psi_j = Injection.find j psi in
						let (j', control) =
							try ((IntMap.find psi_j control), control)
							with | Not_found -> (j, (IntMap.add psi_j j control))
						in
						if not (j' = j)
						then invalid_arg "State.apply: Embedding is clashing"
						else
							(((SiteGraph.node_of_id state.graph (Injection.find j psi)),
									i),
								control)
					with
					| Not_found -> invalid_arg "State.apply: Not a valid embedding")
		with | Not_found -> invalid_arg "State.apply: Incomplete embedding 1" 
	in
	let rec edit state script phi control psi side_effects pert_ids env =
		(* phi: embedding, psi: fresh map *)
		let sg = state.graph
		in
		match script with
		| [] -> (env,state, side_effects, phi, psi, pert_ids)
		| action :: script' ->
				begin
					match action with
					| BND (p, p') ->
							let ((u, i), (v, j), control) =
								let ((u, i), control) = app state control phi psi p in
								let ((v, j), control) = app state control phi psi p'
								in ((u, i), (v, j), control) in
							let env,side_effects,pert_ids =
								bind state (u, i) (v, j) side_effects pert_ids counter env
							in
							edit state script' phi control psi side_effects pert_ids env
					| FREE p ->
							let (x, control) = app state control phi psi p in
							let (warn, env, side_effects,pert_ids) = break state x side_effects pert_ids counter env
							in
							if warn > 0 then Counter.inc_null_action counter ;
							edit state script' phi control psi side_effects pert_ids env
					| MOD (p, i) ->
							let (x, control) = app state control phi psi p in
							let warn,env, pert_ids = modify state x i pert_ids counter env
							in
							if warn > 0 then Counter.inc_null_action counter ; 
							edit state script' phi control psi side_effects pert_ids env
					| DEL i ->
							let phi_i =
								let cc_i = Mixture.component_of_id i mix in
								let inj_opt =
									(try phi.(cc_i)
									with
									| Invalid_argument msg ->
											invalid_arg ("State.apply: " ^ msg)) in
								let inj =
									(match inj_opt with
										| Some inj -> inj
										| None -> invalid_arg "State.apply: no injection")
								in
								(try Injection.find i inj	with Not_found ->	invalid_arg "State.apply: incomplete embedding 3") 
							in
							let (i', control) =
								(try ((IntMap.find phi_i control), control)
								with Not_found -> (i, (IntMap.add phi_i i control)))
							in
							if not (i' = i)
							then invalid_arg "State.apply: embedding is clashing"
							else
								let node_i = SiteGraph.node_of_id sg phi_i in
								let env,side_effects,pert_ids = delete state node_i side_effects pert_ids counter env
								in
								SiteGraph.remove sg phi_i;
								edit state script' phi control psi side_effects pert_ids env
					| ADD (i, name) ->
							let node = Node.create name env in
							let sg' = SiteGraph.add sg node in
							(* sg' might be different address than sg if max array size  *)
							(* was reached                                               *)
							let j =
								(try SiteGraph.( & ) node
								with
								| Not_found -> invalid_arg "State.apply: not allocated") 
							in
							edit {state with graph = sg'} script' phi control	(IntMap.add i j psi) side_effects pert_ids env
				end
	in
	edit state r.script embedding IntMap.empty IntMap.empty Int2Set.empty IntSet.empty env


let snapshot state counter desc env =
	try
		Printf.fprintf desc "# Snapshot [Event: %d, Time: %f]\n" (Counter.event counter) (Counter.time counter) ; 
		let table = Species.of_graph state.graph env in
		Hashtbl.iter
		(fun sign specs ->
			List.iter
			(fun (spec,k) -> Printf.fprintf desc "%%init: %d\t%s\n" k (Species.to_string spec env)) specs
		) table ;
		Printf.fprintf desc "# End snapshot\n" 
	with
		| Sys_error msg -> ExceptionDefn.warning ("Cannot output snapshot: "^msg) 

let dump state counter env =
	if not !Parameter.debugModeOn
	then ()
	else
		(
		let dump_size_of_cc mix =
			let cpt = ref 0 in
			let (cont:string list ref) = ref [] in
			while !cpt < Mixture.arity mix do
				let str = Printf.sprintf "%d" (Mixture.size_of_cc !cpt mix)
				in
					cont := str::!cont ;
					cpt := !cpt+1
			done ;
			("("^(String.concat "," !cont)^")")
		in
		 	Printf.printf "***[%f] Current state***\n" (Counter.time counter);
			SiteGraph.dump ~with_lift: true state.graph env;
			Hashtbl.fold
			(fun i r _ ->
				let nme =
					try "'" ^ ((Environment.rule_of_num i env) ^ "'")
					with | Not_found -> ""
				in
				if Environment.is_rule i env then
					Printf.printf "\t%s %s @ %f(%f) %s\n" nme (Dynamics.to_kappa r)
					(Random_tree.find i state.activity_tree)
					(eval_activity r state counter) (dump_size_of_cc r.lhs)
				else
					Printf.printf "\t%s %s [found %d]\n" nme (Dynamics.to_kappa r)
					(int_of_float (instance_number i state))
			) state.rules ();
			print_newline ();
			Array.iteri
				(fun mix_id opt ->
							match opt with
							| None -> ()
							| Some comp_injs ->
									(Printf.printf "Var[%d]: '%s' %s has %d instances\n" mix_id
											(Environment.kappa_of_num mix_id env)
											(Mixture.to_kappa false (kappa_of_id mix_id state) env)
											(int_of_float (instance_number mix_id state));
										Array.iteri
											(fun cc_id injs_opt ->
														match injs_opt with
														| None -> Printf.printf "\tCC[%d] : na\n" cc_id
														| Some injs ->
																InjectionHeap.iteri
																	(fun inj_id injection ->
																				Printf.printf "\tCC[%d] #%d : %s\n" cc_id inj_id
																					(Injection.to_string injection))
																	injs)
											comp_injs))
				state.injections;
			Array.iteri
				(fun var_id opt ->
							match opt with
							| None ->
									Printf.printf "x[%d]: '%s' na\n" var_id
										(Environment.alg_of_num var_id env)
							| Some (v, x) ->
									Printf.printf "x[%d]: '%s' %f\n" var_id
										(Environment.alg_of_num var_id env)
										(value state var_id counter))
				state.alg_variables;
			IntMap.fold
			(fun i pert _ ->
				Printf.printf "pert[%d]: %s\n" i (Environment.pert_of_num i env)
			)
			state.perturbations ();
			Printf.printf "**********\n"
	)