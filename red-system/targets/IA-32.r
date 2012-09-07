REBOL [
	Title:   "Red/System IA-32 code emitter"
	Author:  "Nenad Rakocevic"
	File: 	 %IA-32.r
	Rights:  "Copyright (C) 2011 Nenad Rakocevic. All rights reserved."
	License: "BSD-3 - https://github.com/dockimbel/Red/blob/master/BSD-3-License.txt"
]

make target-class [
	target: 'IA-32
	little-endian?: yes
	struct-align-size: 	4
	ptr-size: 			4
	default-align:		4
	stack-width:		4
	stack-slot-max:		8							;-- size of biggest datatype on stack (float64!)
	args-offset:		8							;-- stack frame offset to arguments (esp + ebp)
	branch-offset-size:	4							;-- size of JMP offset
	
	fpu-cword: none									;-- x87 control word reference in emitter/symbols
	fpu-flags: to integer! #{037A}					;-- default control word, division by zero
													;-- and invalid operands raise exceptions.
	conditions: make hash! [
	;-- name ----------- signed --- unsigned --
		overflow?		 #{00}		-
		not-overflow?	 #{01}		-	
		=				 #{04}		-
		<>				 #{05}		-
		signed?			 #{08}		-
		unsigned?		 #{09}
		even?			 #{0A}		-
		odd?			 #{0B}		-
		<				 #{0C}		#{02}
		>=				 #{0D}		#{03}
		<=				 #{0E}		#{06}
		>				 #{0F}		#{07}
	]
	
	patch-floats-definition: func [mode [word!] /local value][
		value: pick [unsigned signed] mode = 'set
		foreach w [float! float64! float32!][
			poke find emitter/datatypes w 3 value	;-- force unsigned comparisons (x87 FPU specific)
		]
	]
	
	on-global-prolog: func [runtime? [logic!]][
		patch-floats-definition 'set
		if runtime? [
			emit #{9BDBE3}							;-- FINIT			; init x87 FPU
			fpu-cword: emitter/store-value none fpu-flags [integer!]
		]
	]
	
	on-global-epilog: func [runtime? [logic!]][
		if runtime? [patch-floats-definition 'unset] ;-- restore definitions for next compilation jobs
	]
	
	add-condition: func [op [word!] data [binary!]][
		op: either '- = third op: find conditions op [op/2][
			pick op pick [2 3] signed?
		]
		data/(length? data): (to char! last data) or (to char! first op) ;-- REBOL2's awful binary! handling
		data
	]
	
	emit-float: func [arg opcode [binary!]][
		emit either any [
			arg = 4
			'float32! = first compiler/get-type arg 
		][
			opcode and #{F9FF}
		][
			opcode
		]
	]
	
	emit-float-variable: func [name [word! object!] gcode [binary! block!] lcode [binary! block!]][
		if 'float32! = first compiler/get-type name [
			gcode: gcode and #{F9FF}
			lcode: lcode and #{F9FF} 
		]
		emit-variable name gcode lcode
	]
		
	emit-poly: func [spec [block!] /local w to-bin][	;-- polymorphic code generation
		spec: reduce spec
		w: either width = 8 [4][width]				;-- use splitted 32-bit access for 64-bit word
		emit switch w [
			1 [spec/1]								;-- 8-bit
			2 [emit #{66} spec/2]					;-- 16-bit
			4 [spec/2]								;-- 32-bit
		]
		to-bin: get select [1 to-bin8 2 to-bin16 4 to-bin32] w
		case/all [
			2 < length? spec [emit to-bin to integer! compiler/unbox spec/3] ;-- emit displacement or immediate
			3 < length? spec [emit to-bin to integer! compiler/unbox spec/4] ;-- emit displacement or immediate
		]	
	]
	
	emit-variable-poly: func [							;-- polymorphic variable access generation
		name [word! object!]
		    g8 [binary!] 		g32 [binary!]			;-- opcodes for global variables
			l8 [binary! block!] l32 [binary! block!]	;-- opcodes for local variables
	][
		with-width-of name [
			switch width [
				1 [emit-variable name g8 l8]				;-- 8-bit
				2 [emit #{66} emit-variable name g32 l32]	;-- 16-bit
				4 [emit-variable name g32 l32]				;-- 32-bit
			]
		]
	]
	
	emit-save-last: does [
		last-saved?: yes
		unless compiler/any-float? compiler/last-type [
			emit #{50}								;-- PUSH eax
		]
	]
	
	emit-restore-last: does [
		unless find [float! float64! float32!] compiler/last-type/1 [
			emit #{5A}					   			;-- POP edx
		]
	]
	
	emit-casting: func [value [object!] alt? [logic!] /local old][
		type: compiler/get-type value/data	
		case [
			value/type/1 = 'logic! [
				if verbose >= 3 [print [">>>converting from" mold/flat type/1 "to logic!"]]
				old: width
				set-width/type type/1
				emit #{31DB}						;--		   XOR ebx, ebx
				either alt? [
					emit-poly [#{80FA00} #{83FA00}]	;-- 	   CMP rD, 0
					emit #{7401}					;--        JZ _exit
					emit #{43}						;-- 	   INC ebx
					emit #{89DA}					;-- _exit: MOV edx, ebx
				][
					emit-poly [#{3C00} #{83F800}]	;-- 	   CMP rA, 0
					emit #{7401}					;--        JZ _exit
					emit #{43}						;-- 	   INC ebx
					emit #{89D8}					;-- _exit: MOV eax, ebx
				]
				width: old
			]
			all [value/type/1 = 'integer! type/1 = 'byte!][
				if verbose >= 3 [print ">>>converting from byte! to integer! "]
				emit pick [#{81E2} #{25}] alt?    	;-- AND edx|eax, 000000FFh 
				emit to-bin32 255
			]
			all [value/type/1 = 'integer! type/1 = 'float32!][
				if verbose >= 3 [print [">>>converting from float32! to integer!"]]
				emit #{83EC04}						;-- SUB esp, 4
				emit #{D91C24}						;-- FSTP dword [esp]	; save as 32-bit
				either alt? [
					emit #{5A}						;-- POP edx
				][
					emit #{58}						;-- POP eax
				]
			]
			all [value/type/1 = 'float32! type/1 = 'integer!][
				if verbose >= 3 [print [">>>converting from integer! to float32!"]]
				either alt? [
					emit #{52}						;-- PUSH edx
				][
					emit #{50}						;-- PUSH eax
				]
				emit #{D90424}						;-- FLD dword [esp]		; load as 32-bit
				emit #{83C404}						;-- ADD esp, 4			; free space
			]
			all [find [float! float64!] value/type/1 find [float32! integer!] type/1][
				if verbose >= 3 [print [">>>converting from" mold/flat type/1 "to float!"]]
				either type/1 = 'integer! [
					either alt? [
						emit #{52}					;-- PUSH edx
					][
						emit #{50}					;-- PUSH eax
					]
					emit #{D90424}					;-- FLD dword [esp]		; load as 32-bit
					emit #{83EC04}					;-- SUB esp, 4			; alloc more space for 64-bit float
				][
					emit #{83EC08}					;-- SUB esp, 8			; alloc space for 64-bit float
				]
				emit #{DD1C24}						;-- FSTP qword [esp]	; save as 64-bit
				emit #{DD0424}						;-- FLD qword [esp]		; load as 64-bit
				emit #{83C408}						;-- ADD esp, 8			; free space
			]
			all [value/type/1 = 'float32! find [float! float64!] type/1][
				if verbose >= 3 [print [">>>converting from float! to float32!"]]
				emit #{83EC04}						;-- SUB esp, 4			; alloc space for 32-bit float
				emit #{D91C24}						;-- FSTP dword [esp]	; save as 32-bit
				emit #{D90424}						;-- FLD dword [esp]		; load as 32-bit
				emit #{83C404}						;-- ADD esp, 4			; free space
			]
		]
	]

	emit-load-literal: func [type [block! none!] value /local spec][	
		unless type [type: compiler/get-type value]
		spec: emitter/store-value none value type
		emit #{B8}									;-- MOV eax, value
		emit-reloc-addr spec/2						;-- one-based index
	]
	
	emit-fpu-get: func [
		/type
		/options option [word!]
		/masks mask [word!]
		/cword
		/local value bit 
	][
		unless type [
			emit #{A1}								;-- MOV eax, [fpu-cword]
			emit-reloc-addr fpu-cword/2				;-- one-based index
		]
		case [
			type [
				; hardcoded value for now (FPU_X87)
				emit #{31C0}						;--	XOR eax, eax
				emit #{40}							;--	INC eax				; eax: 1
			]								
			options [
				emit #{25}							;-- AND eax, <value>
				set [value bit] switch/default option [
					rounding  [[#{00000C00} 10]]
					precision [[#{00000300} 8]]
				][
					compiler/throw-error ["invalid FPU option name:" option]
				]
				emit reverse copy value
			]
			masks [
				bit: switch/default mask [
					precision	[5]
					underflow	[4]
					overflow	[3]
					zero-divide [2]
					denormal	[1]
					invalid-op  [0]
				][
					compiler/throw-error ["invalid FPU mask name:" mask]
				]
				emit #{25}							;-- AND eax, 2^bit
				emit to-bin32 shift/left 1 bit
			]
			;cword []								;-- control word is already in eax
		]
		unless any [type cword][
			emit #{C1E8}							;-- SHR eax, <bit>
			emit to-bin8 bit
		]
	]
	
	emit-fpu-set: func [
		value
		/options option [word!]
		/masks mask [word!]
		/cword
		/local bit
	][
		value: to integer! value	
		unless cword [
			emit #{A1}								;-- MOV eax, [fpu-cword]
			emit-reloc-addr fpu-cword/2				;-- one-based index
			emit #{25}								;-- AND eax, 2^bit
		]
		case [
			options [
				set [mask bit] switch/default option [
					rounding  [[#{00000C00} 10]]
					precision [[#{00000300} 8]]
				][
					compiler/throw-error ["invalid FPU option name:" option]
				]
				emit reverse complement mask
			]
			masks [
				bit: switch/default mask [
					precision	[5]
					underflow	[4]
					overflow	[3]
					zero-divide [2]
					denormal	[1]
					invalid-op  [0]
				][
					compiler/throw-error ["invalid FPU mask name:" mask]
				]
				emit to-bin32 complement shift/left 1 bit
			]
		]
		either cword [
			emit #{B8}								;-- MOV eax, <value>
		][
			value: shift/left value bit
			emit #{0D}								;-- OR eax, <value>	
		]
		emit to-bin32 value
		
		emit #{A3}									;-- MOV [fpu-cword], eax
		emit-reloc-addr fpu-cword/2					;-- one-based index
	]
	
	emit-fpu-update: does [
		emit #{D92D}								;-- FLDCW <word>	; load 16-bit control word from memory
		emit-reloc-addr fpu-cword/2					;-- one-based index
	]
	
	emit-get-pc: does [
		emit #{E800000000}							;-- CALL next		; call the next instruction
		emit-pop									;-- get eip in eax
	]
	
	emit-set-stack: func [value /frame][
		if verbose >= 3 [print [">>>emitting SET-STACK" mold value]]
		unless tag? value [emit-load value]
		either frame [
			emit #{89C5}							;-- MOV ebp, eax		
		][
			emit #{89C4}							;-- MOV esp, eax
		]
	]
	
	emit-get-stack: func [/frame][
		if verbose >= 3 [print ">>>emitting GET-STACK"]
		either frame [
			emit #{89E8}							;-- MOV eax, ebp			
		][
			emit #{89E0}							;-- MOV eax, esp
		]
	]
	
	emit-pop: does [
		if verbose >= 3 [print ">>>emitting POP"]
		emit #{58}									;-- POP eax
	]
		
	emit-not: func [value [word! char! tag! integer! logic! path! string! object!] /local opcodes type boxed][
		if verbose >= 3 [print [">>>emitting NOT" mold value]]
		
		if object? value [boxed: value]
		value: compiler/unbox value
		if block? value [value: <last>]

		opcodes: [
			logic!	 [emit #{3401}]					;-- XOR al, 1			; invert 0<=>1
			byte!	 [emit #{F6D0}]					;-- NOT al				; @@ missing 16-bit support									
			integer! [emit #{F7D0}]					;-- NOT eax
		]
		switch type?/word value [
			logic! [
				emit-load not value
			]
			char! [
				emit-load value
				do opcodes/byte!
			]
			integer! [
				emit-load value
				do opcodes/integer!
			]
			word! [
				emit-load value
				if boxed [emit-casting boxed no]
				type: first compiler/resolve-aliased compiler/get-variable-spec value
				if find [pointer! c-string! struct!] type [ ;-- type casting trap
					type: 'logic!
				]
				switch type opcodes
			]
			tag! [
				if boxed [
					emit-casting boxed no
					compiler/last-type: boxed/type
				]
				switch compiler/last-type/1 opcodes
			]
			string! [								;-- type casting trap
				emit-load value
				if boxed [emit-casting boxed no]
				do opcodes/logic!
			]
			path! [
				emitter/access-path value none
				either boxed [
					emit-casting boxed no
					switch boxed/type/1 opcodes 
				][
					do opcodes/integer!
				]
			]
		]
	]
	
	emit-boolean-switch: does [
		emit #{31C0}								;-- 	  XOR eax, eax	; eax = 0 (FALSE)
		emit #{EB03}								;-- 	  JMP _exit
		emit #{31C0}								;--		  XOR eax, eax
		emit #{40}									;--		  INC eax		; eax = 1 (TRUE)
													;-- _exit:
		reduce [3 7]								;-- [offset-TRUE offset-FALSE]
	]
	
	emit-load: func [
		value [char! logic! integer! word! string! path! paren! get-word! object! decimal!]
		/alt
		/with cast [object!]
		/local offset
	][
		if verbose >= 3 [print [">>>loading" mold value]]
		alt: to logic! alt
		
		switch type?/word value [
			char! [
				emit #{B0}							;-- MOV al, value
				emit value
			]
			logic! [
				emit #{31C0}						;-- XOR eax, eax		; eax = 0 (FALSE)	
				if value [
					emit #{40}						;-- INC eax				; eax = 1 (TRUE)
				]
			]
			integer! [
				emit #{B8}							;-- MOV eax, value
				emit to-bin32 value
			]
			decimal! [
				set-width any [cast value]
				emit-push any [cast value]
				emit-float width #{DD0424}			;-- FLD [esp]
				emit #{83C4} 						;-- ADD esp, 8|4
				emit to-bin8 pick [4 8] to logic! all [cast cast/type/1 = 'float32!]
			]
			word! [
				with-width-of value [
					either compiler/any-float? compiler/get-variable-spec value [
						emit-float-variable value
							#{DD05}					;-- FLD [value]			; global
							#{DD45}					;-- FLD [ebp+n]			; local
					][
						either alt [
							emit-variable-poly value
								#{8A15} #{8B15}		;-- MOV rD, [value]		; global
								#{8A55} #{8B55}		;-- MOV rD, [ebp+n]		; local
						][
							emit-variable-poly value
								#{A0}   #{A1}		;-- MOV rA, [value]		; global
								#{8A45} #{8B45}		;-- MOV rA, [ebp+n]		; local	
						]
					]
				]
			]
			get-word! [
				value: to word! value
				either 'function! = first compiler/get-type value [
					either alt [
						emit-variable value
							#{8B15}					;-- MOV edx, [value]	; global
							#{8B55}					;-- MOV edx, [ebp+n]	; local
					][
						emit-variable value
							#{A1}					;-- MOV eax, [value]	; global
							#{8B45}					;-- MOV eax, [ebp+n]	; local	
					]
				][
					either offset: select emitter/stack value [
						emit pick [
							#{8D55}					;-- LEA edx, [ebp+n]	; local
							#{8D45}					;-- LEA eax, [ebp+n]	; local
						] alt
						emit stack-encode offset	;-- n
					][
						emit pick [
							#{BA}					;-- MOV edx, &name
							#{B8}					;-- MOV eax, &name
						] alt
						emit-reloc-addr emitter/get-symbol-ref value	;-- symbol address
					]
				]
			]
			string! [
				emit-load-literal [c-string!] value
			]
			path! [
				emitter/access-path value none
			]
			paren! [
				emit-load-literal none value
			]
			object! [
				unless any [block? value/data value/data = <last>][
					either alt [
						emit-load/alt/with value/data value
					][
						emit-load/with value/data value
					]
				]
				;emit-casting value no
				;compiler/last-type: value/type
			]
		]
	]
	
	emit-store: func [
		name [word!] value [char! logic! integer! word! string! paren! tag! get-word! decimal!]
		spec [block! none!]
		/local store-dword type
	][
		if verbose >= 3 [print [">>>storing" mold name mold value]]
		if value = <last> [value: 'last]			;-- force word! code path in switch block
		if logic? value [value: to integer! value]	;-- TRUE -> 1, FALSE -> 0
		
		store-dword: [
			emit-variable name
				#{C705}								;-- MOV dword [name], value		; global
				#{C745}								;-- MOV dword [ebp+n], value	; local
		]
		
		switch type?/word value [
			char! [
				emit-variable name
					#{C605}							;-- MOV byte [name], value
					#{C645}							;-- MOV byte [ebp+n], value
				emit value
			]
			integer! [
				do store-dword
				emit to-bin32 value
			]
			decimal! [
				emit-float-variable name 
					#{DD1D}							;-- FSTP [name]			; global
					#{DD5D}							;-- FSTP [ebp+n]		; local
			]
			word! [
				either compiler/any-float? compiler/get-variable-spec name [
					emit-float-variable name 
						#{DD1D}						;-- FSTP [name]			; global
						#{DD5D}						;-- FSTP [ebp+n]		; local
				][
					set-width name				
					emit-variable-poly name
						#{A2} 	#{A3}				;-- MOV [name], rA		; global variable
						#{8845} #{8945}				;-- MOV [ebp+n], rA		; local variable
				]
			]
			get-word! [
				either find emitter/stack to word! value [
					emit-store name <last> none
				][
					do store-dword
					emit-reloc-addr emitter/get-symbol-ref to word! value	;-- symbol address
				]
			]
			string! [
				do store-dword
				emit-reloc-addr spec/2
			]
			paren! [
				do store-dword
				emit-reloc-addr spec/2
			]
		]
	]
	
	emit-init-path: func [name [word!]][
		emit-variable name
			#{A1}									;-- MOV eax, [name]			; global
			#{8B45}									;-- MOV eax, [ebp+n]		; local
	]
	
	emit-access-path: func [
		path [path! set-path!] spec [block! none!] /short /local offset type saved
	][
		if verbose >= 3 [print [">>>accessing path:" mold path]]

		unless spec [
			spec: second compiler/resolve-type path/1
			emit-init-path path/1
		]
		if short [return spec]
		
		saved: width
		type: compiler/resolve-type/with path/2 spec

		set-width/type type/1						;-- adjust operations width to member value size
		offset: emitter/member-offset? spec path/2
		
		either compiler/any-float? type [
			either zero? offset [
				emit-float width #{DD00}			;-- FLD [eax]
			][
				emit-float width #{DD80}			;-- FLD [eax+offset]
				emit to-bin32 offset
			]
		][
			either zero? offset [
				emit-poly [#{8A00} #{8B00}]			;-- MOV rA, [eax]
			][
				emit-poly [#{8A80} #{8B80}]			;-- MOV rA, [eax+offset]
				emit to-bin32 offset
			]
		]
		width: saved
	]
		
	emit-load-index: func [idx [word!]][
		emit-variable idx
			#{8B1D}									;-- MOV ebx, [idx]		; global
			#{8B5D}									;-- MOV ebx, [ebp+n]	; local
		emit #{4B}									;-- DEC ebx				; one-based index
	]
	
	emit-c-string-path: func [path [path! set-path!] parent [block! none!] /local opcodes idx][
		either parent [
			emit #{89C6} 							;-- MOV esi, eax		; nested access
		][
			emit-variable path/1
				#{8B35}								;-- MOV esi, [value1]	; global
				[
					#{8D45}							;-- LEA eax, [ebp+n]	; local
					offset							;-- n
					#{8B30}							;-- MOV esi, [eax]
				]
		]
		opcodes: pick [[							;-- store path opcodes --
				#{8816}								;-- MOV [esi], dl			; first	
				#{8896}								;-- MOV [esi + idx], dl 	; n-th
				#{88141E}							;-- MOV [esi + ebx], dl 	; variable index
			][										;-- load path opcodes --
				#{8A06}								;-- MOV al, [esi]			; first
				#{8A86}								;-- MOV al, [esi + idx]		; n-th
				#{8A041E}							;-- MOV al, [esi + ebx]		; variable index
		]] set-path? path
		
		either integer? idx: path/2 [
			either zero? idx: idx - 1 [				;-- indexes are one-based
				emit opcodes/1
			][
				emit opcodes/2
				emit to-bin32 idx
			]
		][
			emit-load-index idx
			emit opcodes/3
		]
	]
	
	emit-pointer-path: func [
		path [path! set-path!] parent [block! none!] /local opcodes idx type offset
	][
		type: either parent [
			compiler/resolve-type/with path/1 parent
		][
			emit-init-path path/1
			compiler/resolve-type path/1
		]
		set-width/type type/2/1						;-- adjust operations width to pointed value size
		idx: either path/2 = 'value [1][path/2]
		
		either compiler/any-float? type/2 [
			opcodes: pick [[						;-- store path opcodes --
				#{DD18}								;-- FSTP [eax]
				#{DD98}								;-- FSTP [eax + <idx> * sizeof(p/value)]
				#{DD1C}								;-- FSTP [eax + ebx * sizeof(p/value)]
			][										;-- load path opcodes --
				#{DD00}								;-- FLD [eax]
				#{DD80}								;-- FLD [eax + <idx> * sizeof(p/value)]
				#{DD04}								;-- FLD [eax + ebx * sizeof(p/value)]
			]] set-path? path

			either integer? idx [
				either zero? idx: idx - 1 [			;-- indexes are one-based
					emit-float width opcodes/1
				][
					offset: idx * emitter/size-of? type/2/1	;-- scaled index up
					emit-float width opcodes/2
					emit to-bin32 offset
				]
			][
				emit-load-index idx
				emit-float width opcodes/3
				emit select [4 #{98} 8 #{D8}] width
			]
		][
			opcodes: pick [[						;-- store path opcodes --
				[#{8810} #{8910}]					;-- MOV [eax], rD
				[#{8890} #{8990}]					;-- MOV [eax + <idx> * sizeof(p/value)], rD
				[#{881418} #{891498}]				;-- MOV [eax + ebx * sizeof(p/value)], rD
			][										;-- load path opcodes --
				[#{8A00} #{8B00}]					;-- MOV rA, [eax]
				[#{8A80} #{8B80}]					;-- MOV rA, [eax + <idx> * sizeof(p/value)]
				[#{8A0418} #{8B0498}]				;-- MOV rA, [eax + ebx * sizeof(p/value)]
			]] set-path? path

			either integer? idx [
				either zero? idx: idx - 1 [			;-- indexes are one-based
					emit-poly opcodes/1
				][
					offset: idx * emitter/size-of? type/2/1	;-- scaled index up
					emit-poly opcodes/2
					emit to-bin32 offset
				]
			][
				emit-load-index idx
				emit-poly opcodes/3
			]
		]
	]
	
	emit-load-path: func [path [path!] type [word!] parent [block! none!] /local idx][
		if verbose >= 3 [print [">>>loading path:" mold path]]

		switch type [
			c-string! [emit-c-string-path path parent]
			pointer!  [emit-pointer-path  path parent]
			struct!   [emit-access-path   path parent]
		]
	]

	emit-store-path: func [
		path [set-path!] type [word!] value parent [block! none!]
		/local idx offset
	][
		if verbose >= 3 [print [">>>storing path:" mold path mold value]]

		if parent [emit #{89C2}]					;-- MOV edx, eax			; save value/address
		unless value = <last> [emit-load value]
		emit #{89D6}								;-- MOV esi, edx
		emit #{92}									;-- XCHG eax, edx			; save value/restore address

		switch type [
			c-string! [emit-c-string-path path parent]
			pointer!  [emit-pointer-path  path parent]
			struct!   [
				unless parent [parent: emit-access-path/short path parent]
				type: compiler/resolve-type/with path/2 parent
				
				set-width/type type/1				;-- adjust operations width to member value size
				offset: emitter/member-offset? parent path/2
				
				either compiler/any-float? type [
					either zero? offset [
						emit-float width #{DD18}	;-- FSTP [eax]
					][
						emit-float width #{DD98}	;-- FSTP [eax+offset]
						emit to-bin32 offset
					]
				][
					either zero? offset [
						emit-poly [#{8810} #{8910}] ;-- MOV [eax], rD
					][
						emit-poly [#{8890} #{8990}]	;-- MOV [eax+offset], rD
						emit to-bin32 offset
					]
				]
			]
		]
	]
	
	patch-exit-call: func [code-buf [binary!] ptr [integer!] exit-point [integer!]][
		change at code-buf ptr to-bin32 exit-point - ptr - branch-offset-size
	]
	
	emit-exit: does [
		emit #{E9}									;-- JMP imm32
		emit-reloc-addr compose/only [- - (emitter/exits)]
	]

	emit-branch: func [
		code [binary!]
		op [word! block! logic! none!]
		offset [integer! none!]
		/back?
		/local size imm8? opcode jmp
	][
		if verbose >= 3 [print [">>>inserting branch" either op [join "cc: " mold op][""]]]
		
		size: (length? code) - any [offset 0]				;-- offset from the code's head
		imm8?: size <= either back? [126][127]				;-- account 2 bytes for JMP imm8
		opcode: either not none? op [						;-- explicitly test for none
			op: case [
				block? op [									;-- [cc] => keep
					op: op/1
					either logic? op [pick [= <>] op][op]	;-- [logic!] or [cc]
				]
				logic? op [pick [= <>] op]					;-- test for TRUE/FALSE
				'else 	  [opposite? op]					;-- 'cc => invert condition
			]
			add-condition op copy pick [#{70} #{0F80}] imm8? ;-- Jcc offset 	; 8/32-bit displacement
		][
			pick [#{EB} #{E9}] imm8?						;-- JMP offset 	; 8/32-bit displacement
		]
		if back? [size: negate (size + (length? opcode) + pick [1 4] imm8?)]
		jmp: rejoin [opcode either imm8? [to-bin8 size][to-bin32 size]]
		insert any [all [back? tail code] code] jmp
		length? jmp
	]
	
	emit-push: func [
		value [char! logic! integer! word! block! string! tag! path! get-word! object! decimal!]
		/with cast [object!]
		/cdecl										;-- external call
		/local spec type offset
	][
		if verbose >= 3 [print [">>>pushing" mold value]]
		if block? value [value: <last>]
		
		switch type?/word value [
			tag! [									;-- == <last>
				either compiler/any-float? compiler/last-type [
					set-width/type any [all [cast cast/type] compiler/last-type]
					emit join #{83EC} to-bin8 width	;-- SUB esp, 8|4
					emit-float width #{DD1C24}		;-- FSTP [esp]
				][
					emit #{50}						;-- PUSH eax
				]
			]
			logic! [
				emit #{31C0}						;--	XOR eax, eax		; eax = 0 (FALSE)	
				if value [
					emit #{40}						;--	INC eax				; eax = 1 (TRUE)
				]
				emit #{50}							;-- PUSH eax
			]
			char! [
				emit #{6A}							;-- PUSH value
				emit value
			]
			integer! [
				either all [-128 <= value value <= 127][
					emit #{6A}						;-- PUSH imm8
					emit to-bin8 value
				][
					emit #{68}						;-- PUSH imm32		
					emit to-bin32 value	
				]
			]
			decimal! [
				value: either all [cast cast/type/1 = 'float32! not cdecl][
					IEEE-754/to-binary32/rev value
				][
					value: IEEE-754/to-binary64/rev value
					emit #{68}						;-- PUSH high part		
					emit at value 5
					value
				]
				emit #{68}							;-- PUSH low part
				emit copy/part value 4
			]
			word! [
				type: compiler/get-variable-spec value
				either compiler/any-float? type [
					either cdecl [width: 8][			;-- promote to C double if required
						set-width/type any [all [cast cast/type] type]
					]
					
					emit #{83EC}					;-- SUB esp, 8|4
					emit to-bin8 width
					emit-float-variable value
						#{DD05}						;-- FLD [value]			; global
						#{DD45}						;-- FLD [ebp+n]			; local
					emit-float width #{DD1C24}		;-- FSTP [esp]			; push double on stack
				][
					emit-variable value
						#{FF35}						;-- PUSH [value]		; global
						#{FF75}						;-- PUSH [ebp+n]		; local
				]
			]
			get-word! [
				value: to word! value
				either offset: select emitter/stack value [
					emit #{8D45}					;-- LEA eax, [ebp+n]	; local
					emit stack-encode offset		;-- n
					emit #{50}						;-- PUSH eax
				][
					emit #{68}						;-- PUSH &value
					emit-reloc-addr emitter/get-symbol-ref value	;-- symbol address
				]
			]
			string! [
				spec: emitter/store-value none value [c-string!]
				emit #{68}							;-- PUSH value
				emit-reloc-addr spec/2				;-- one-based index
			]
			path! [
				emitter/access-path value none
				compiler/last-type: either cast [
					emit-casting cast no
					cast/type
				][
					compiler/resolve-path-type value
				]
				emit-push <last>
			]
			object! [
				unless any [
					path? value/data
					compiler/any-float? compiler/get-type value/data 
				][
					emit-casting value no
				]
				either cdecl [
					emit-push/with/cdecl value/data value
				][
					emit-push/with value/data value
				]
			]
		]
	]
	
	emit-sign-extension: does [
		emit switch width [
			1 [#{6698}]								;-- CBW			; extend AL to AX
			2 [#{6699}]								;-- CWD			; extend AX to DX:AX
			4 [#{99}]								;-- CDQ			; extend EAX to EDX:EAX
		]
	]
	
	emit-bitshift-op: func [name [word!] a [word!] b [word!] args [block!] /local c value][
		switch b [
			ref [
				emit-variable args/2
					#{8A0D}							;-- MOV cl, byte [value]	; global
					#{8A4D}							;-- MOV cl, byte [ebp+n]	; local
			]
			reg [emit #{88D1}]						;-- MOV cl, dl
		]
		switch name [
			<<  [
				emit-poly pick [
					[#{C0E0} #{C1E0}]				;-- SAL|SHL rA, value
					[#{D2E0} #{D3E0}]				;-- SAL|SHL rA, cl
				] b = 'imm
			]
			>>  [
				emit-poly pick [
					[#{C0F8} #{C1F8}]				;-- SAR rA, value
					[#{D2F8} #{D3F8}]				;-- SAR rA, cl
				] b = 'imm
			]
			-** [
				emit-poly pick [
					[#{C0E8} #{C1E8}]				;-- SHR rA, value
					[#{D2E8} #{D3E8}]				;-- SHR rA, cl
				] b = 'imm
			]
		]
		if b = 'imm [
			c: select [1 7 2 15 4 31] width
			value: compiler/unbox args/2		
			unless all [0 <= value value <= c][		
				compiler/backtrack name
				compiler/throw-error rejoin [
					"a value in 0-" c " range is required for this shift operation"
				]
			]
			emit to-bin8 value
		]
	]
	
	emit-bitwise-op: func [name [word!] a [word!] b [word!] args [block!] /local code][		
		code: select [
			and [
				#{25}								;-- AND eax, value
				#{21D0}								;-- AND eax, edx		; commutable op
			]
			or [
				#{0D}								;-- OR eax, value
				#{09D0}								;-- OR eax, edx			; commutable op
			]
			xor [
				#{35}								;-- XOR eax, value
				#{31D0}								;-- XOR eax, edx		; commutable op
			]
		] name
		
		switch b [
			imm [
				emit code/1							;-- <OP> eax, value
				emit to-bin32 compiler/unbox args/2
			]
			ref [
				emit-load/alt args/2
				if object? args/2 [emit-casting args/2 yes]
				emit code/2
			]
			reg [emit code/2]						;-- <OP> eax, edx		; commutable op
		]
	]
	
	emit-comparison-op: func [name [word!] a [word!] b [word!] args [block!] /local op-poly][
		op-poly: [emit-poly [#{38D0} #{39D0}]]		;-- CMP rA, rD			; not commutable op
		
		switch b [
			imm [
				emit-poly [#{3C} #{3D} args/2]		;-- CMP rA, value
			]
			ref [
				emit-load/alt args/2
				if object? args/2 [emit-casting args/2 yes]
				do op-poly
			]
			reg [
				do op-poly
			]
		]
	]
	
	emit-math-op: func [
		name [word!] a [word!] b [word!] args [block!]
		/local mod? scale c type arg2 op-poly
	][
		;-- eax = a, edx = b
		if find [// ///] name [						;-- work around unaccepted '// and '///
			mod?: select [// mod /// rem] name		;-- convert operators to words (easier to handle)
			name: first [/]							;-- work around unaccepted '/ 
		]
		arg2: compiler/unbox args/2
		
		if all [
			find [+ -] name							;-- pointer arithmetic only allowed for + & -
			type: compiler/resolve-expr-type args/1
			not compiler/any-pointer? compiler/resolve-expr-type args/2	;-- no scaling if both operands are pointers		
			scale: switch type/1 [
				pointer! [emitter/size-of? type/2/1]		  ;-- scale factor: size of pointed value
				struct!  [emitter/member-offset? type/2 none] ;-- scale factor: total size of the struct
			]
			scale > 1
		][
			either compiler/literal? arg2 [
				arg2: arg2 * scale					;-- 'b is a literal, so scale it directly
			][
				either b = 'reg [
					emit #{92}						;-- XCHG eax, edx		; put operands in right order
				][									;-- 'b will now be stored in reg, so save 'a			
					emit-poly [#{88C2} #{89C2}]		;-- MOV rD, rA
					emit-load args/2
				]
				emit-math-op '* 'reg 'imm reduce [arg2 scale]
				if name = '- [emit #{92}]			;-- XCHG eax, edx		; put operands in right order
				b: 'reg
			]
		]
		;-- eax = a, edx = b
		switch name [
			+ [
				op-poly: [
					emit-poly [#{00D0} #{01D0}]		;-- ADD rA, rD			; commutable op
				]
				switch b [
					imm [
						emit-poly either arg2 = 1 [	;-- trivial optimization
							[#{FEC0} #{40}]			;-- INC rA
						][
							[#{04} #{05} arg2] 		;-- ADD rA, value
						]
					]
					ref [
						emit-load/alt args/2
						do op-poly
					]
					reg [do op-poly]
				]
			]
			- [
				op-poly: [
					emit-poly [#{28D0} #{29D0}] 	;-- SUB rA, rD			; not commutable op
				]
				switch b [
					imm [
						emit-poly either arg2 = 1 [ ;-- trivial optimization
							[#{FEC8} #{48}]			;-- DEC rA
						][
							[#{2C} #{2D} arg2] 		;-- SUB rA, value
						]
					]
					ref [
						emit-load/alt args/2
						do op-poly
					]
					reg [do op-poly]
				]
			]
			* [
				op-poly: [
					emit-poly [#{F6EA} #{F7EA}] ;-- IMUL rD 			; commutable op
				]
				switch b [
					imm [
						either all [
							not zero? arg2
							c: power-of-2? arg2		;-- trivial optimization for b=2^n
						][
							either width = 1 [
								emit #{C0E0}		;-- SHL al, log2(b)	; 8-bit unsigned
							][
								emit-poly [#{C0ED} #{C1E0}]	;-- SAL rA, log2(b) ; signed
							]
							emit to-bin8 c
						][
							unless width = 1 [emit #{52}]  ;-- PUSH edx	; save edx from corruption for 16/32-bit ops
							with-width-of/alt args/2 [							
								emit-poly [#{B2} #{BA} args/2] ;-- MOV rD, value
							]
							emit #{89D3}				   ;-- MOV ebx, edx
							emit-poly [#{F6EB} #{F7EB}]	   ;-- IMUL rB		; result in ax|eax|edx:eax
							unless width = 1 [emit #{5A}]  ;-- POP edx
						]
					]
					ref [
						emit #{52}					;-- PUSH edx	; save edx from corruption
						emit-load/alt args/2
						do op-poly
						emit #{5A}					;-- POP edx
					]
					reg [do op-poly]
				]
			]
			/ [
				op-poly: [
					either width = 1 [				;-- 8-bit unsigned
						emit #{B400}				;-- MOV ah, 0			; clean-up garbage in ah
						emit #{F6F3}				;-- DIV bl
					][
						emit-sign-extension			;-- 16/32-bit signed
						emit-poly [#{F6FB} #{F7FB}]	;-- IDIV rB ; rA / rB
					]
				]
				switch b [
					imm [							;-- SAR usage http://www.arl.wustl.edu/~lockwood/class/cs306/books/artofasm/Chapter_6/CH06-3.html#HEADING3-120
						emit #{52}					;-- PUSH edx	; save edx from corruption
						with-width-of/alt args/2 [							
							emit-poly [#{B2} #{BA} args/2] ;-- MOV rD, value
						]
						emit #{89D3}				;-- MOV ebx, edx
						do op-poly
					]
					ref [
						emit #{52}					;-- PUSH edx	; save edx from corruption
						emit-load/alt args/2
						emit #{89D3}				;-- MOV ebx, edx
						do op-poly
					]
					reg [
						emit #{89D3}				;-- MOV ebx, edx		; ebx = b
						do op-poly
					]
				]
				if mod? [
					emit-poly [#{88E0} #{89D0}]		;-- MOV rA, remainder	; remainder from ah|dx|edx
					if all [mod? <> 'rem width > 1][;-- modulo, not remainder
					;-- Adjust modulo result to be mathematically correct:
					;-- 	if modulo < 0 [
					;--			if divisor < 0  [divisor: negate divisor]
					;--			modulo: modulo + divisor
					;--		]
						c: to-bin8 select [1 7 2 15 4 31] width		;-- support for possible int8 type
						emit #{0FBAE0}				;--   	  BT rA, 7|15|31 ; @@ better way ?
						emit c
						emit #{730A}				;-- 	  JNC exit		 ; (won't work with ax)
						emit #{0FBAE3}				;-- 	  BT rB, 7|15|31 ; @@ better way ?
						emit c
						emit #{7302}				;-- 	  JNC add		 ; (won't work with ax)
						emit-poly [#{F6DB} #{F7DB}]	;--		  NEG rB
						emit-poly [#{00D8} #{01D8}]	;-- add:  ADD rA, rB
					]								;-- exit:
				]
				if any [							;-- in case edx was saved on stack
					all [b = 'imm any [mod? not c]]
					b = 'ref
				][
					emit #{5A}						;-- POP edx
				]
			]
		]
		;TBD: test overflow and raise exception ? (or store overflow flag in a variable??)
		; JNO? (Jump if No Overflow)
	]
	
	emit-integer-operation: func [name [word!] args [block!] /local a b sorted? left right][
		if verbose >= 3 [print [">>>inlining integer op:" mold name mold args]]

		set-width args/1							;-- set reg/mem access width
		set [a b] get-arguments-class args
		last-saved?: no								;-- reset flag

		;-- First operand processing
		left:  compiler/unbox args/1
		right: compiler/unbox args/2
		
		switch to path! reduce [a b] [
			imm/imm	[emit-poly [#{B0} #{B8} args/1]];-- MOV rA, a
			imm/ref [emit-load args/1]				;-- eax = a
			imm/reg [								;-- eax = b
				if path? right [
					emit-load args/2				;-- late path loading
					if object? args/2 [
						emit-casting args/2 no
					]
				]
				emit-poly [#{88C2} #{89C2}]			;-- MOV rD, rA
				emit-poly [#{B0} #{B8} args/1]		;-- MOV rA, a		; eax = a, edx = b
			]
			ref/imm [emit-load args/1]
			ref/ref [emit-load args/1]
			ref/reg [								;-- eax = b
				if path? right [
					emit-load args/2				;-- late path loading
				]
				emit-poly [#{88C2} #{89C2}]			;-- MOV rD, rA	
				emit-load args/1					;-- eax = a, edx = b
			]
			reg/imm [								;-- eax = a (or edx = a if last-saved)
				if path? left [
					emit-load args/1				;-- late path loading
				]
				if last-saved? [emit #{92}]			;-- XCHG eax, edx	; eax = a
			]
			reg/ref [								;-- eax = a (or edx = a if last-saved)
				if path? left [
					emit-load args/1				;-- late path loading
				]
				if last-saved? [emit #{92}]			;-- XCHG eax, edx	; eax = a
			]
			reg/reg [								;-- eax = b, edx = a
				if path? left [
					if block? args/2 [				;-- edx = b
						emit #{92}					;-- XCHG eax, edx
						sorted?: yes				;-- eax = a, edx = b
					]
					emit-load args/1				;-- late path loading
				]
				if path? right [
					emit #{92}						;-- XCHG eax, edx	; eax = b, edx = a
					emit-load args/2
				]
				unless sorted? [emit #{92}]			;-- XCHG eax, edx	; eax = a, edx = b
			]
		]
		if object? args/1 [emit-casting args/1 no]	;-- do runtime conversion on eax if required

		;-- Operator and second operand processing
		either all [object? args/2 find [imm reg] b][
			emit-casting args/2 yes					;-- do runtime conversion on edx if required
		][
			implicit-cast right
		]
		case [
			find comparison-op name [emit-comparison-op name a b args]
			find math-op	   name	[emit-math-op		name a b args]
			find bitwise-op	   name	[emit-bitwise-op	name a b args]
			find bitshift-op   name [emit-bitshift-op   name a b args]
		]
	]
	
	emit-float-trash-last: does [
		emit #{DDD8}								;-- FSTP st0
	]
	
	emit-float-comparison-op: func [
		name [word!] a [word!] b [word!] args [block!] reversed? [logic!]
		/local spec float32?
	][
		if reversed? [emit #{D9C9}]					;-- FXCH st0, st1
		
		either compiler/job/cpu-version >= 6.0	[	;-- support for FCOMI* only with P6+
			emit #{DFF1}							;-- FCOMIP st0, st1
			emit-float-trash-last					;-- pop 2nd argument
		][
			emit #{D8D9}							;-- FCOMP st0, st1
			emit #{DDD8}							;-- FSTP st0		; pop 2nd argument
			emit #{9BDFE0}							;-- FSTSW ax		; move FPU flags to ax
			emit #{9B}								;-- FWAIT			; wait for FPU->CPU transfer completion
			emit #{9E}								;-- SAHF			; move flags to CPU status flags
		]
	]
	
	emit-float-math-op: func [
		name [word!] a [word!] b [word!] args [block!] reversed? [logic!]
		/local mod? scale c type spec
	][
		all [
			find [+ -] name	
			any [
				compiler/any-pointer? compiler/get-type args/1
				compiler/any-pointer? compiler/get-type args/2
			]
			compiler/throw-error "unsupported operation with float numbers"
		]
		
		if find [// ///] name [						;-- work around unaccepted '// and '///
			mod?: select [// mod /// rem] name		;-- convert operators to words (easier to handle)
			name: first [/]							;-- work around unaccepted '/ 
		]
		set-width args/1
		emit switch name [
			+ [#{DEC1}]								;-- FADDP st0, st1
			- [pick [#{DEE1} #{DEE9}] reversed?]	;-- FSUB[R]P st0, st1
			* [#{DEC9}]								;-- FMULP st0, st1
			/ [
				if all [mod? reversed?][
					emit #{D9C9}					;-- FXCH st0, st1		; for modulo/remainder ops
				]
				switch/default mod? [
					mod [#{D9F8}]					;-- FPREM st0, st1		; floating point remainder
					rem [
						compiler/last-type: [integer!]
						#{D9F5}						;-- FPREM1 st0, st1 	; rounded remainder (IEEE)
					]
				][pick [#{DEF1} #{DEF9}] reversed?]	;-- FDIV[R]P st0, st1
			]
		]
	]

	emit-float-operation: func [
		name [word!] args [block!] 
		/local a b left right spec load-from-stack reversed?
	][
		if verbose >= 3 [print [">>>inlining float op:" mold name mold args]]

		if find comparison-op name [reverse args] 	;-- arguments will be pushed in reverse order
		
		set [a b] get-arguments-class args

		;-- First operand processing
		left:  compiler/unbox args/1
		right: compiler/unbox args/2
		set-width left
		
		load-from-stack: [
			emit-float width #{DD0424}				;-- FLD [esp]
			emit #{83C4} 							;-- ADD esp, 8|4
			emit to-bin8 width		
		]

		switch a [									;-- load left operand on FPU stack
			imm [
				spec: emitter/store-value none args/1 compiler/get-type args/1
				emit-float args/1 #{DD05}			;-- FLD [<float>]	; load immediate from data segment
				emit-reloc-addr spec/2
				set-width args/1
			]
			ref [			
				emit-float-variable left
					#{DD05}							;-- FLD [value]		; global
					#{DD45}							;-- FLD [ebp+n]		; local
				if object? args/1 [emit-casting args/1 no]
			]
			reg [
				if object? args/1 [
					if block? left [emit-casting args/1 no]
					set-width/type compiler/last-type: args/1/type
				]
				if path? left [
					emit-push args/1				;-- late path loading
					do load-from-stack
				]
			]
		]		
		switch b [									;-- load right operand on FPU stack
			imm [
				spec: emitter/store-value none args/2 compiler/get-type args/2
				emit-float args/2 #{DD05}			;-- FLD [<float>]
				emit-reloc-addr spec/2
			]
			ref [
				emit-float-variable right
					#{DD05}							;-- FLD [value]		; global
					#{DD45}							;-- FLD [ebp+n]		; local
				if object? args/2 [emit-casting args/2 no]
			]
			reg [
				if all [object? args/2 block? right][
					emit-casting args/2 no
				]
				if path? right [
					emit-push args/2
					do load-from-stack
				]
			]
		]
		
		reversed?: to logic! any [
			all [b = 'reg any [all [a = 'ref block? right] all [a = 'imm block? right]]]
			all [a = 'reg any [all [b = 'ref path? left] all [b = 'imm path? left]]]
		]
		
		case [
			find comparison-op name [emit-float-comparison-op name a b args reversed?]
			find math-op	   name	[emit-float-math-op		  name a b args reversed?]
			true [
				compiler/throw-error "unsupported operation on floats"
			]
		]
	]
	
	emit-cdecl-pop: func [spec [block!] args [block!] /local size][
		size: emitter/arguments-size? spec/4
		if all [
			spec/2 = 'syscall
			compiler/job/syscall = 'BSD
		][
			size: size + stack-width				;-- account for extra space
		]
		if issue? args/1 [							;-- test for variadic call
			size: call-arguments-size? args/2
			if spec/2 = 'native [
				size: size + pick [12 8] args/1 = #typed 	;-- account for extra arguments
			]
		]
		emit #{83C4}								;-- ADD esp, n		; @@ 8-bit offset only?
		emit to-bin8 size
	]
	
	patch-call: func [code-buf rel-ptr dst-ptr][
		change										;-- CALL NEAR disp size
			at code-buf rel-ptr
			to-bin32 dst-ptr - rel-ptr - ptr-size
	]
	
	emit-argument: func [arg fspec [block!]][
		if arg = #_ [exit]							;-- place-holder, no code to emit
		
		either all [
			object? arg
			any [arg/type = 'logic! 'byte! = first compiler/get-type arg/data]
			not path? arg/data
		][
			unless block? arg [emit-load arg]		;-- block! means last value is already in eax (func call)
			emit-casting arg no
			compiler/last-type: arg/type			;-- for inline unary functions
			emit-push <last>
		][
			if block? arg [arg: <last>]
			either all [
				fspec/3 = 'cdecl 
				block? fspec/4/1
				find fspec/4/1 'variadic			;-- only for vararg C functions
			][
				emit-push/cdecl arg					;-- promote float32! to float!
			][
				emit-push arg
			]
		]
	]
		
	emit-call-syscall: func [args [block!] fspec [block!]][
		switch compiler/job/syscall [
			BSD [									; http://www.freebsd.org/doc/en/books/developers-handbook/book.html#X86-SYSTEM-CALLS
				emit #{83EC04}						;-- SUB esp, 4		; extra entry (BSD convention)			
			]
			Linux [
				if fspec/1 >= 6 [
					emit #{89E8}					;-- MOV eax, ebp	; save frame pointer
				]
				repeat c fspec/1 [
					emit pick [
						#{5B}						;-- POP ebx			; get 1st arg in reg
						#{59}						;-- POP ecx			; get 2nd arg in reg
						#{5A}						;-- POP edx			; get 3rd arg in reg
						#{5E}						;-- POP esi			; get 4th arg in reg
						#{5F}						;-- POP edi			; get 5th arg in reg
						#{5D}						;-- POP ebp			; get 6th arg in reg
					] 1 + fspec/1 - c
				]
				if fspec/1 >= 6 [
					emit #{50}						;-- PUSH eax		; save frame pointer on stack
				]
			]
		]
		emit #{B8}									;-- MOV eax, code
		emit to-bin32 last fspec
		emit #{CD80}								;-- INT 0x80		; syscall
		switch compiler/job/syscall [
			BSD [emit-cdecl-pop fspec args]			;-- BSD syscall cconv (~ cdecl)
			Linux [
				if fspec/1 >= 6 [emit #{5D}]		;-- POP ebp			; restore frame pointer
			]
		]
	]
	
	emit-call-import: func [args [block!] fspec [block!] spec [block!]][
		either compiler/job/OS = 'MacOSX [
			emit #{B8}								;-- MOV eax, addr
			emit-reloc-addr spec
			emit #{FFD0} 							;-- CALL eax		; direct call
		][	
			emit #{FF15}							;-- CALL FAR [addr]	; indirect call
			emit-reloc-addr spec
		]
		if fspec/3 = 'cdecl [						;-- add calling cleanup when required
			emit-cdecl-pop fspec args
		]
	]

	emit-call-native: func [args [block!] fspec [block!] spec [block!] /routine /local total][
		if issue? args/1 [							;-- variadic call
			emit-push call-arguments-size? args/2	;-- push arguments total size in bytes 
													;-- (required to clear stack on stdcall return)
			emit #{8D742404}						;-- LEA esi, [esp+4]	; skip last pushed value
			emit #{56}								;-- PUSH esi			; push arguments list pointer
			total: length? args/2
			if args/1 = #typed [total: total / 3]	;-- typed args have 3 components
			emit-push total							;-- push arguments count
		]
		either routine [
			emit #{FF15}							;-- CALL FAR [addr]	; indirect call
		][
			emit #{E8}								;-- CALL NEAR disp
		]
		emit-reloc-addr spec						;-- 32-bit (FAR: pointer to addr, NEAR: relative displacement)
		if fspec/3 = 'cdecl [						;-- in case of non-default calling convention
			emit-cdecl-pop fspec args
		]
	]
	
	emit-stack-align-prolog: func [args [block!] /local offset][
		if compiler/job/stack-align-16? [
			emit #{89E7}							;-- MOV edi, esp
			emit #{83E4F0}							;-- AND esp, -16
			offset: 4								;-- account for saved edi
			if issue? args/1 [args: args/2]
			offset: offset + call-arguments-size? args
			
			unless zero? offset: offset // 16 [
				emit #{83EC}						;-- SUB esp, offset		; ensure call will be 16-bytes aligned
				emit to-bin8 16 - offset
			]
			emit #{57}								;-- PUSH edi
		]
	]
	
	emit-stack-align-epilog: func [args [block!]][
		if compiler/job/stack-align-16? [
			emit #{5C}								;-- POP esp
		]
	]

	emit-prolog: func [name [word!] locals [block!] locals-size [integer!] /local fspec][
		if verbose >= 3 [print [">>>building:" uppercase mold to-word name "prolog"]]

		emit #{55}									;-- PUSH ebp
		emit #{89E5}								;-- MOV ebp, esp
		unless zero? locals-size [
			emit #{83EC}							;-- SUB esp, locals-size
			emit to-char round/to/ceiling locals-size 4		;-- limits total local variables size to 255 bytes
		]
		fspec: select compiler/functions name
		if all [block? fspec/4/1 fspec/5 = 'callback][
			emit #{53}								;-- PUSH ebx
			emit #{56}								;-- PUSH esi
			emit #{57}								;-- PUSH edi
		]
	]

	emit-epilog: func [
		name [word!] locals [block!] args-size [integer!] locals-size [integer!]
		/local fspec
	][
		if verbose >= 3 [print [">>>building:" uppercase mold to-word name "epilog"]]

		fspec: select compiler/functions name
		if all [block? fspec/4/1 fspec/5 = 'callback][
			emit #{5F}								;-- POP edi
			emit #{5E}								;-- POP esi
			emit #{5B}								;-- POP ebx
		]
		emit #{C9}									;-- LEAVE
		either any [
			zero? args-size
			fspec/3 = 'cdecl
		][
			;; cdecl: Leave original arguments on stack, popped by caller.
			emit #{C3}								;-- RET
		][
			;; stdcall/reds: Consume original arguments from stack.
			either compiler/check-variable-arity? locals [
				emit #{5E}							;-- POP esi			; retrieve the return address
				emit #{5B}							;-- POP ebx			; skip arguments count
				emit #{5B}							;-- POP ebx			; skip arguments pointer
				emit #{5B}							;-- POP ebx			; get stack offset
				emit #{01DC}						;-- ADD esp, ebx	; skip arguments list (clears stack)
				emit #{56}							;-- PUSH esi		; push return address
				emit #{C3}							;-- RET
			][
				emit #{C2}							;-- RET args-size
				emit to-bin16 round/to/ceiling args-size 4
			]
		]
	]
]
