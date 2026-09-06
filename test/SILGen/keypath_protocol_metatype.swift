// RUN: %target-swift-emit-silgen -module-name test %s | %FileCheck %s
// RUN: %target-swift-emit-silgen-ossa -module-name test -o /dev/null -enable-sil-opaque-values %s
// RUN: %target-swift-emit-silgen -module-name test %s -enable-library-evolution
// RUN: %target-swift-emit-silgen -module-name test %s -enable-testing
// RUN: %target-swift-emit-silgen -module-name test %s -enable-library-evolution -enable-testing

// A key path rooted at a protocol metatype may refer to a static requirement of
// the protocol. The component is dispatched through the protocol witness table,
// so no property descriptor needs to be emitted for it.

protocol P {
  static var foo: Int { get }
  static subscript(index: Int) -> Int { get }
}

struct S {
  init(_ kp: KeyPath<P.Type, Int>) {}
}

func makeKeyPath() {
  S(\.foo)
}

func makeSubscriptKeyPath() {
  S(\.[0])
}

// The component is identified by the witness, not by a property descriptor.
// CHECK-LABEL: sil hidden [ossa] @$s4test11makeKeyPathyyF
// CHECK:         keypath $KeyPath<any P.Type, Int>,
// CHECK-SAME:      (root $any P.Type;
// CHECK-SAME:       gettable_property $Int,
// CHECK-SAME:       id #P.foo!getter :

// The getter thunk opens the existential metatype and dispatches through the
// witness table.
// CHECK-LABEL: sil shared [thunk] [ossa] @$s4test1PP3fooSivpZAaB_pXpTK : $@convention(keypath_accessor_getter) (@in_guaranteed @thick any P.Type) -> @out Int {
// CHECK:       bb0([[OUT:%.*]] : $*Int, [[BASE:%.*]] : $*@thick any P.Type):
// CHECK:         [[EXIST:%.*]] = load [trivial] [[BASE]]
// CHECK:         [[META:%.*]] = open_existential_metatype [[EXIST]] to $@thick (@opened({{.*}}, any P) Self).Type
// CHECK:         [[WITNESS:%.*]] = witness_method $@opened({{.*}}, any P) Self, #P.foo!getter
// CHECK:         [[RESULT:%.*]] = apply [[WITNESS]]<@opened({{.*}}, any P) Self>([[META]])
// CHECK:         store [[RESULT]] to [trivial] [[OUT]]
// CHECK:       } // end sil function

// A static subscript requirement works the same way, with the index carried in
// the key path's index buffer and the usual equality/hash helpers emitted.
// CHECK-LABEL: sil hidden [ossa] @$s4test20makeSubscriptKeyPathyyF
// CHECK:         keypath $KeyPath<any P.Type, Int>,
// CHECK-SAME:      (root $any P.Type;
// CHECK-SAME:       gettable_property $Int,
// CHECK-SAME:       id #P.subscript!getter :
// CHECK-SAME:       indices [%$0 : $Int : $Int],
// CHECK-SAME:       indices_equals @$sSiTH :
// CHECK-SAME:       indices_hash @$sSiTh :

// The subscript thunk takes the index as a second argument, opens the
// existential metatype, and dispatches through the witness table.
// CHECK-LABEL: sil shared [thunk] [ossa] @$s4test1PPyS2icipZAaB_pXpxTK : $@convention(keypath_accessor_getter) (@in_guaranteed @thick any P.Type, @in_guaranteed Int) -> @out Int {
// CHECK:       bb0([[OUT:%.*]] : $*Int, [[BASE:%.*]] : $*@thick any P.Type, [[INDEX:%.*]] : $*Int):
// CHECK:         [[EXIST:%.*]] = load [trivial] [[BASE]]
// CHECK:         [[META:%.*]] = open_existential_metatype [[EXIST]] to $@thick (@opened({{.*}}, any P) Self).Type
// CHECK:         [[I:%.*]] = load [trivial] [[INDEX]]
// CHECK:         [[WITNESS:%.*]] = witness_method $@opened({{.*}}, any P) Self, #P.subscript!getter
// CHECK:         [[RESULT:%.*]] = apply [[WITNESS]]<@opened({{.*}}, any P) Self>([[I]], [[META]])
// CHECK:         store [[RESULT]] to [trivial] [[OUT]]
// CHECK:       } // end sil function

// Protocol requirements never use an external key path component, so no
// property descriptor is emitted for 'P.foo' or 'P.subscript'.
// CHECK-NOT: sil_property
