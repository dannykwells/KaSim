module InjSet = Set.Make (Mods.Injection)

type t = {mutable injs : InjSet.t}

let iter f ls = InjSet.iter f ls.injs

let fold f ls cont = InjSet.fold f ls.injs cont

let add ls inj = (ls.injs <- InjSet.add inj ls.injs);ls
	
let remove ls inj = ls.injs <- InjSet.remove inj ls.injs

let create s = {injs = InjSet.empty}

let flush ls = ls.injs <- InjSet.empty 