// RUN: %target-typecheck-verify-swift

protocol P {
  static var foo: Int { get }
  var inst: Int { get }
}

let _: KeyPath<P.Type, P.Type> = \.self

func ordinaryLookup(_ type: P.Type) -> Int {
  type.foo
}

let kp: KeyPath<P.Type, Int> = \.foo

func takesKeyPath(_ kp: KeyPath<P.Type, Int>) {}

takesKeyPath(\.foo)

class C {
  static let classMember: Int = 42
}

protocol Q: C {}

let classMemberKeyPath: KeyPath<any Q.Type, Int> = \.classMember

let _: KeyPath<any P, Int> = \.foo
// expected-error@-1 {{static member 'foo' cannot be used on instance of type 'any P'}}

let _: KeyPath<any P.Type, Int> = \.inst
// expected-error@-1 {{instance member 'inst' cannot be used on type 'P'}}
