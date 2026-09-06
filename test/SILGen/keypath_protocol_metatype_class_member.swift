// RUN: %target-swift-emit-silgen -module-name test %s | %FileCheck %s
// RUN: %target-swift-emit-silgen-ossa -module-name test -o /dev/null -enable-sil-opaque-values %s
// RUN: %target-swift-emit-silgen -module-name test %s -enable-library-evolution
// RUN: %target-swift-emit-silgen -module-name test %s -enable-testing
// RUN: %target-swift-emit-silgen -module-name test %s -enable-library-evolution -enable-testing

// A key path rooted at a protocol metatype can reach a static member that the
// protocol inherits from its class constraint. Such a member is not a protocol
// requirement, so it is dispatched on the class metatype rather than through a
// witness table: the existential metatype is opened and then upcast to the
// declaring class's metatype.

class Base {
  static let storedMember: Int = 42
  static var computedMember: Int { 7 }
}

protocol ClassConstrained: Base {}

func storedMemberKeyPath() -> KeyPath<any ClassConstrained.Type, Int> {
  \.storedMember
}

func computedMemberKeyPath() -> KeyPath<any ClassConstrained.Type, Int> {
  \.computedMember
}

// The component is identified by the class member's getter, not by a witness.
// CHECK-LABEL: sil hidden [ossa] @$s4test19storedMemberKeyPath
// CHECK:         keypath $KeyPath<any ClassConstrained.Type, Int>,
// CHECK-SAME:      (root $any ClassConstrained.Type;
// CHECK-SAME:       gettable_property $Int,
// CHECK-SAME:       id @$s4test4BaseC12storedMemberSivgZ : $@convention(method) (@thick Base.Type) -> Int,

// The getter thunk opens the existential metatype and upcasts it to the
// declaring class's metatype. It must not use witness_method: the member is
// inherited from the class constraint, not a protocol requirement.
// CHECK-LABEL: sil shared [thunk] [ossa] @$s4test4BaseC12storedMemberSivpZAA16ClassConstrained_pXpTK : $@convention(keypath_accessor_getter) (@in_guaranteed @thick any ClassConstrained.Type) -> @out Int {
// CHECK:       bb0([[OUT:%.*]] : $*Int, [[BASE:%.*]] : $*@thick any ClassConstrained.Type):
// CHECK:         [[EXIST:%.*]] = load [trivial] [[BASE]]
// CHECK:         [[OPENED:%.*]] = open_existential_metatype [[EXIST]] to $@thick (@opened({{.*}}, ClassConstrained) Self).Type
// CHECK:         upcast [[OPENED]] to $@thick Base.Type
// CHECK-NOT:     witness_method
// CHECK:       } // end sil function

// For a computed member the upcast metatype is what gets passed to the getter,
// so the upcast is load-bearing rather than dead.
// CHECK-LABEL: sil shared [thunk] [ossa] @$s4test4BaseC14computedMemberSivpZAA16ClassConstrained_pXpTK : $@convention(keypath_accessor_getter) (@in_guaranteed @thick any ClassConstrained.Type) -> @out Int {
// CHECK:         [[OPENED2:%.*]] = open_existential_metatype {{%.*}} to $@thick (@opened({{.*}}, ClassConstrained) Self).Type
// CHECK:         [[UPCAST:%.*]] = upcast [[OPENED2]] to $@thick Base.Type
// CHECK:         [[GETTER:%.*]] = function_ref @$s4test4BaseC14computedMemberSivgZ
// CHECK:         apply [[GETTER]]([[UPCAST]])
// CHECK-NOT:     witness_method
// CHECK:       } // end sil function

// Applying the key paths type-checks and lowers.
func useKeyPaths(_ t: any ClassConstrained.Type) -> Int {
  t[keyPath: storedMemberKeyPath()] + t[keyPath: computedMemberKeyPath()]
}
