# 키패스 프로토콜 메타타입 패치 — 리뷰 결과와 수정 제안

2026-08-31 멀티에이전트 리뷰(finder 10 + verifier 3 + sweep 1, 전부 이 워킹트리로 빌드한
asserts 툴체인으로 실증) 결과 정리. 대상: `keypath-protocol-metatype` 브랜치의
미커밋 변경 11파일 + 신규 테스트 1파일.

**요약.** 패치의 핵심은 견고하다 — Sema가 새로 허용하고 SILGen이 배운 형태들
(요구사항 get/set, 익스텐션 정적 멤버, 클래스 제약 멤버, `class var` 동적 디스패치,
합성 루트, 파라미터라이즈드 프로토콜, `@objc`, 크로스 모듈/레질리언트, appending,
동등성/해시, `-O`)은 전부 올바르게 동작함을 실행으로 확인했다. 문제는 경계선이다:
**Sema 금지를 통째로 걷어내면서, SILGen이 아직 못 내리는 5가지 형태가 진단 대신
컴파일러 크래시가 됐다.** 업스트림 PR 전에 이것들을 막아야 한다.

라인 번호는 현재 워킹트리 기준.

---

## A. 기본 플래그에서 크래시 (반드시 수정)

### A1. `Self`/associatedtype 타입 정적 요구사항 → SILGen ASSERT

- 위치: `lib/SILGen/SILGenExpr.cpp:5029` (유입 지점은 `lib/Sema/CSFix.cpp:1388`)
- 재현 (둘 다 asserts 빌드에서 abort 확인):

  ```swift
  protocol P { static var shared: Self { get } }
  let kp = \(any P.Type).shared

  // 표준 라이브러리로도 재현 — typecheck는 통과, SILGen에서 크래시:
  let keyPathToShared: KeyPath<any GlobalActor.Type, any Actor> = \.shared
  ```

- 원인: `emitKeyPathComponentForDecl`의 VarDecl 분기에서 existential 루트일 때
  `var->getValueInterfaceType()`를 그대로 componentTy로 쓰고
  `ASSERT(!componentTy->hasTypeParameter())`로 못박는다 (5026–5029행).
  `Self`나 associatedtype이 들어 있으면 어서션이 터진다.
- **핵심 관찰: Sema는 이미 공변 소거(covariant erasure)를 끝냈다.** 위 GlobalActor
  예제는 `-typecheck`가 깨끗이 통과하고, 키패스의 Value 타입을 `any Actor`로
  이미 지워 놓았다 (SE-0309의 직접 멤버 접근 `type.shared`와 같은 의미론).
  크래시는 SILGen이 AST가 정한 컴포넌트 타입을 무시하고 인터페이스 타입에서
  다시 유도하기 때문이다.

**전략 (2026-09-01 결정): 이 PR에서는 좁힌 Sema 가드, 소거 지원은 후속 PR.**

근거: 이 크래시 계열은 인스턴스 existential 루트에서 **main에도 이미 있는 기존
버그**다 — `\(any P).a` (associatedtype), `\(any P).shared` (`Self`) 둘 다 출시된
6.3.3 **릴리스** 컴파일러가 같은 어서션(그쪽 소스 기준 SILGenExpr.cpp:4851)으로
죽는 것을 확인했다. 인스턴스 레벨 버그를 static 도입 PR에서 고칠 이유는 없다.
다만 메타타입 루트 형태는 패치 전에는 깨끗한 진단이었으므로, 진단→크래시 퇴행을
막는 최소한의 가드는 이 PR에 있어야 한다.

**이 PR: 좁힌 Sema 가드 (~10줄).** `AllowInvalidRefInKeyPath::forRef`
(CSFix.cpp:1388 부근)에서, 삭제한 fix를 좁힌 형태로 되살린다:

```cpp
if (auto *metatype = baseRValueType->getAs<AnyMetatypeType>()) {
  if (metatype->getInstanceType()->isExistentialType()) {
    auto memberTy = member->getValueInterfaceType();
    if (memberTy->hasTypeParameter() || memberTy->hasDynamicSelfType())
      return AllowInvalidRefInKeyPath::create(/* 좁힌 RefKind + 새 진단 */);
  }
}
```

- `hasTypeParameter()`가 A1(프로토콜 요구사항의 `Self`/associatedtype)과
  A4(첨자 element 타입)를, `hasDynamicSelfType()`이 A3(클래스 멤버의 `Self`)를
  커버한다. 진단 문구는 옛 blanket 메시지 대신 이유를 말해주는 것으로
  (예: "key path to static member %0 of protocol metatype root is not
  supported when its type involves 'Self' or associated types").
- CSFix.h의 RefKind와 CSDiagnostics의 진단 클래스를 좁힌 이름으로 일부 복원해야
  한다 (patch가 삭제한 `ProtocolMetatypeStaticMember` 인프라의 축소판).
- `GlobalActor.shared`는 이 PR에서는 (크래시 대신) 에러가 된다 — 트레이드오프.

**후속 PR: SILGen 공변 소거 지원.** 가드를 제거하면서:

1. `KeyPathExpr::Component::getComponentType()` (Sema가 소거해 둔 타입, 예:
   `any Actor`)을 `visitKeyPathExpr` → `emitKeyPathComponentForDecl`로 전달하고,
   existential 루트 분기(5026–5029)에서는 재유도 대신 그것을 componentTy로 쓴다.
   - 주의: `emitKeyPathComponentForDecl`은 property descriptor 방출
     (`SILGen.cpp`의 `emitPropertyDescriptor`)에서도 불리는데, 그 경로에는 AST
     컴포넌트가 없다. 다만 descriptor는 프로토콜 멤버에 대해 아예 안 만들어지므로
     (`lib/SIL/IR/SIL.cpp:513-515`) existential 분기와는 겹치지 않는다 —
     AST 타입이 없으면 기존 재유도로 폴백하면 된다.
2. getter thunk (`getOrCreateKeyPathGetter` 경로)에서 위트니스 호출 결과가
   의존 타입(`(@opened Self).ActorType` 등)일 때 `@out` componentTy로 소거를
   방출한다: 결과를 임시에 받고 `init_existential_addr`(클래스 바운드면
   `init_existential_ref`)로 감싼다. 필요한 conformance는 opened archetype의
   requirement signature에서 나온다 (`ActorType: Actor`). 전부 기존 SIL 기계로
   가능하고, `emitExistentialErasure` 계열 헬퍼가 이미 있다.
3. 소거된 컴포넌트는 읽기 전용이어야 하는데, 직접 접근과 마찬가지로 Sema가 이미
   `KeyPath`(non-writable)만 준다 — setter thunk 쪽은 손댈 것 없음.
4. `baseTy->isAnyExistentialType()`는 컨테이너/메타타입 둘 다 매치하므로, 이
   수정은 **인스턴스 루트의 기존 크래시(6.3에도 있는 것)까지 같이 고친다** —
   그 PR의 본론이 되는 셈이다.

### A2. `AnyObject.Type` 루트 + @objc 클래스 정적 멤버 → null 역참조

- 위치: `lib/SILGen/SILGenExpr.cpp:3648`
- 재현: (asserts 빌드 "Cannot dereference a null Type!", no-asserts는 UB)

  ```swift
  import Foundation
  class C: NSObject { @objc static var x: Int = 7 }
  let kp: KeyPath<AnyObject.Type, Int> = \.x   // AnyObject dynamic lookup
  ```

- 원인: AnyObject dynamic lookup으로 찾은 멤버는 선언 클래스(`C`)가 루트의 클래스
  바운드 계층에 없으므로 `opened->getSuperclassForDecl(propertyClass)`가 null을
  반환하고, 바로 `->getCanonicalType()`을 부른다. 패치 전에는 삭제된 Sema 진단이
  막아 주던 형태다.

**수정 제안: Sema에서 `AnyObject` 루트와 똑같이 진단한다** (제안대로).
기존 인프라를 그대로 거울처럼 확장하면 된다:

- `include/swift/AST/DiagnosticsSema.def:735`의
  `expr_swift_keypath_anyobject_root` ("the root type of a Swift key path cannot
  be 'AnyObject'") 옆에 메타타입용 항목을 추가하거나, 메시지를 `%0`을 받게
  일반화해서 `'AnyObject.Type'`도 찍게 한다.
- 탐지 지점 두 곳 확장: `lib/Sema/CSSimplify.cpp:4805` (KeyPathRoot locator에서
  `AllowAnyObjectKeyPathRoot::create`)와 `lib/Sema/CSSimplify.cpp:10531`/`11503`
  (`UR_KeyPathWithAnyObjectRootType`). 현재는 루트가 `isAnyObject()`인 경우만
  잡으므로, `rootTy->is<ExistentialMetatypeType>() &&
  rootTy->getMetatypeInstanceType()->isAnyObject()`를 추가한다.
- 진단 방출은 `lib/Sema/CSDiagnostics.cpp:6675`.
- 방어적으로 SILGen 3648에도 null 체크 assert(메시지 포함)를 남겨 두면
  나중에 다른 경로로 새는 걸 빨리 잡는다.

### A3. 클래스 바운드 경유 `Self` 반환 정적 멤버 → SIL verifier abort

- 위치: `lib/SILGen/SILGenExpr.cpp:5034` (componentTy의 else 분기 5030–5041)
- 재현:

  ```swift
  class FB { static var shared: Self { self.init() }; required init() {} }
  protocol FQ: FB {}
  let kp = \(any FQ.Type).shared
  // → "keypath value type should match value type of keypath pattern / any FQ / FB"
  ```

- 원인: Sema는 값 타입을 `any FQ`로 소거했는데, else 분기의 치환은
  `@dynamic_self FB` → `FB`만 하고 existential 소거는 모른다. 패턴과 AST가
  어긋나 SIL verifier가 죽는다.

**전략:** A1의 좁힌 가드가 이 형태도 커버한다 (`hasDynamicSelfType()` 쪽).
이 계열 역시 인스턴스 레벨에서 **main에도 있는 기존 버그**임을 확인했다 —
심지어 `Self` 타입이 아니어도 터진다:

```swift
final class FB: Sendable { let val = FB(); required init() {} }
protocol FQ: FB {}
let kp = \(any FQ).val
// 6.3.3 릴리스: 컴파일 OK → 런타임에 libswiftCore 안에서 크래시 (키패스 인스턴스화)
// main+패치 asserts: SILGen OK → IRGen UNREACHABLE "not struct or class"
//                    (lib/IRGen/GenKeyPath.cpp:760)
```

같은 모듈의 stored 클래스 멤버는 stored-offset 컴포넌트로 내려가는데
(`canStorageUseStoredKeyPathComponent`), GenKeyPath가 existential 루트를 처리하지
못한다 — 크로스 모듈 레질리언트 케이스는 external descriptor 경로라서 동작한다.
패치와 무관한 기존 버그이므로 known issue로 기록하고 별도 PR (아래 G절).
후속 소거 PR에서의 thunk 처리도 미묘한 점만 메모: getter는 정적으로 `FB`를
반환하지만 동적으로는 Self이므로, `any FQ`로 넣으려면 `unchecked_ref_cast`로
opened archetype 타입으로 되돌린 뒤 archetype의 conformance로
`init_existential_ref` 해야 한다.

### A4. `Self` 반환 정적 첨자 → SIL verifier abort

- 위치: `lib/SILGen/SILGenExpr.cpp:5083` (SubscriptDecl 분기)
- 재현:

  ```swift
  protocol P { static subscript(i: Int) -> Self { get } }
  let kp = \(any P.Type)[0]
  // → opened archetype이 컴포넌트 타입으로 새어 verifier abort
  ```

- 원인: 첨자 분기에는 VarDecl 분기(5026)에 있는 existential 특례조차 없어서,
  `substGenericArgs(subs)` 결과에 opened archetype이 그대로 남는다.

**전략:** A1의 좁힌 가드가 커버한다 (첨자의 element 인터페이스 타입에
`hasTypeParameter()`). 인스턴스 아날로그(`\(any P)[0]`)는 main asserts 빌드에서
같은 SIL verifier abort를 확인했고, 6.3.3 릴리스는 verifier가 꺼져 있어 silgen을
통과해 잠복한다 — 역시 기존 버그, known issue(G절). 후속 소거 PR에서
VarDecl/Subscript 두 분기가 같은 처리를 공유하도록 리팩터링하면 (지금은
componentTy 계산이 두 벌) 같은 실수가 재발하지 않는다.

---

## B. 잘못된 진단 (기능을 부당하게 막음)

### B1. pre-6.1 swiftinterface 모듈 게이트가 프로토콜 요구사항을 오탐

- 위치: `lib/Sema/CSFix.cpp:1378-1384` (base-shape 검사 1388보다 먼저 실행됨)
- 재현 확인: swift-compiler-version을 6.0.3으로 조작한 swiftinterface의
  `protocol Greeter { static var greeting: String { get } }`에 대해
  `\.greeting` → "key path cannot refer to static member ... from module" 에러.
- 왜 오탐인가: 이 게이트의 근거는 "옛 모듈에는 정적 멤버용 descriptor/accessor
  심볼이 없다"인데, 프로토콜 요구사항 컴포넌트는 descriptor를 아예 안 쓴다
  (`shouldUseExternalKeyPathComponent`, SILGenExpr.cpp:4929-4932). 방출되는
  thunk는 `open_existential_metatype` + `witness_method`로 전부 클라이언트
  쪽이며, 정의 모듈의 심볼을 하나도 참조하지 않는다 (SIL 덤프로 확인).

**수정 제안:** 1374행 조건에 `!isa<ProtocolDecl>(member->getDeclContext())`를
더해 위트니스 디스패치 요구사항은 게이트를 건너뛴다. 클래스 제약 멤버
(`Q: C` 경유 `C`의 정적 멤버)는 descriptor를 실제로 쓰므로 게이트를 유지한다.
버전 라인을 조작한 swiftinterface로 양쪽을 고정하는 테스트 추가.

---

## C. feature-gated 크래시 (`KeyPathWithMethodMembers` 필요 — PR에서 언급, 후속 수정 가능)

### C1. unapplied 정적 메서드 키패스 → `isAbstract()` assert

- 위치: `lib/SILGen/SILGenApply.cpp:8051`
- 재현: `protocol P { static func m(_ x: Int) -> Int }; let kp = \(any P.Type).m`
- 원인: `emitUnappliedKeyPathMethod`가 `emitKeyPathRValueBase`가 opened archetype의
  **메타타입**으로 바꿔 놓은 `baseType`을 그대로 `lookupConformance`의 Self로
  쓴다. applied 형태 `\.m(1)`은 이 패치 덕에 잘 된다.
- **수정 제안:** conformance lookup 전에 메타타입이면
  `baseType->getMetatypeInstanceType()`을 쓴다. 인스턴스 루트 `\(any P).m`도
  같은 이유로 (패치 전부터) 죽으므로 같은 수정으로 함께 고쳐진다.

### C2. `\(any P.Type).init(x:)` → `mapTypeOutOfEnvironment` assert

- 위치: `lib/SILGen/SILGenExpr.cpp:4841`. 생성자는 삭제된 금지의 적용 대상이
  아니었어서 (조건이 `isStatic() && !isa<FuncDecl>`) 엄밀히는 기존 버그 인접.
  결과 타입의 `Self`를 치환/소거한 뒤 매핑해야 한다 — A1 인프라를 재사용.

### C3. 메서드 키패스 id가 링크 불가 심볼 방출

- 위치: `lib/SILGen/SILGenExpr.cpp:4880`. `\(any P.Type).m()`이 컴파일은 되지만
  요구사항의 독립 진입점(`$s…FZ`)을 참조해 링크 실패. 인스턴스 existential
  루트도 동일한 기존 버그 — 이 패치가 원인은 아니므로 PR 본문에 알려진 상호작용으로
  기록만.

---

## D. 잠복 사항 (동작은 맞음 — 문서화/테스트 권장)

### D1. external descriptor가 existential 레이아웃 펀닝에 의존 (PLAUSIBLE)

- 위치: `lib/SILGen/SILGenExpr.cpp:4987` 경로
- 레질리언트 `LibA`의 `public class Base { public static var w: Int }` +
  `public protocol Q: Base {}`에서 `\(any Q.Type).w`는 `external #Base.w`가 되고,
  런타임은 descriptor의 accessor(`@in_guaranteed @thick Base.Type`, 1워드)를
  클라이언트의 2워드 existential 메타타입 버퍼에 그대로 적용한다 (lldb로 확인:
  descriptor getter 3회, 클라이언트 thunk 0회 — 결과는 정확).
- 스칼라 existential이 값을 offset 0에 놓는 게 동결된 ABI라서
  (`GenExistential.cpp:290-297`) 오늘은 안전하고, 같은 의존이 인스턴스
  existential 루트로 이미 출시돼 있다. 다만 문서화도 테스트도 없다.
- **제안:** 크로스 모듈 레질리언트 실행 테스트 하나로 고정하고, 필요하면
  `KeyPath.swift`의 external component 해석부에 주석 한 줄.

### D2. `SILGenLValue.cpp:5852` — `AnyMetatypeType` 완화는 죽은 코드

- lldb로 전 경로 확인: 이 지점에 도달하는 base는 항상 구체 클래스 메타타입
  (`$@thick Base.Type`)이고, existential 메타타입은 도달 불가 (키패스 base는
  `emitKeyPathRValueBase`가 먼저 열고 upcast; 직접 접근은 이 함수를 아예
  안 탐 — 브레이크포인트 0회). **제안: 이 hunk를 되돌린다.** 개발 중
  open/upcast가 들어가기 전의 잔재로 보이며, 되돌리면 더 엄격한 tripwire가
  복원된다. 어느 테스트도 깨지지 않음을 확인했다.

---

## E. 테스트 커버리지 보강

- 새로 합법화된 형태 중 SILGen 테스트가 없는 것: 프로토콜 익스텐션 정적 멤버,
  `@objc` 프로토콜 정적 (optional 포함), 합성 루트 `any (P & Q).Type`,
  settable 익스텐션 정적. 전부 지금은 동작하지만
  `subs.getReplacementTypes()[0]->castTo<ExistentialArchetypeType>()`
  (SILGenExpr.cpp:3638) 가정 위에 있어서, 치환 리팩터링이 조용히 깨뜨릴 수 있다.
- setter thunk를 SIL 수준에서 확인하는 CHECK가 없다 (opaque-values RUN은
  `-o /dev/null`). `ReferenceWritableKeyPath` 요구사항 setter와 클래스 멤버
  setter의 SIL을 고정할 것.
- 좁힌 가드(A1)를 넣으면 A1/A3/A4의 재현 입력을 expected-error 진단 테스트로
  추가 — 후속 소거 PR에서 그 테스트들이 실행 테스트로 바뀐다.

---

## F. 정리 (동작 문제 아님)

1. **분기 통합 (SILGenExpr.cpp:3631):** 새 existential-메타타입 분기는 바로 아래
   인스턴스-existential 분기의 구조적 복제다. `isAnyExistentialType()`는
   `ExistentialMetatypeType`도 매치하고 (`include/swift/AST/Types.h:8526-8528`)
   `emitOpenExistential`이 Metatype 표현을 이미 처리하므로
   (`SILGenConvert.cpp:1036-1039`) 열기는 한 분기로 합칠 수 있고, upcast는
   3679–3691의 가드된 블록(새 복제본이 빠뜨린 `DynamicSelfType` unwrap과
   `baseClass != propertyClass` 가드 포함)을 공유할 수 있다. 합치면
   `getSelfClassDecl()` 중복 호출(3633/3646)과 `MetatypeType::get(...)
   ->getCanonicalType()` 체인(→ `CanMetatypeType::get`)도 함께 사라진다.
2. **저장 정적 멤버의 죽은 open+upcast (3643):** static stored 필드는
   `emitRValueForStorageLoad`가 base를 버리므로, 저장 프로퍼티일 때는
   열지 말고 그대로 반환하면 thunk마다 죽은 SIL 두 개와 opened environment
   할당이 없어진다. (새 테스트의 CHECK도 그에 맞춰 수정.)
3. **RUN 매트릭스 (두 SILGen 테스트의 3–5행):** evolution/testing 플래그는
   이 파일들 내용에 대해 RUN 1과 다른 경로를 못 탄다 (descriptor는 프로토콜
   멤버에 대해 생략, 정적 멤버는 항상 computed component). RUN 1(FileCheck) +
   RUN 2(opaque values)만 남기거나 프리픽스로 차별화.
4. **`CSFix.cpp:1387`:** `baseRValueType` 지역 변수는 삭제된 검사의 잔재 —
   조건식에 인라인.

---

## G. known issues — main에도 있는 기존 버그 (이 PR 범위 밖, 별도 PR/이슈)

전부 이 패치와 무관하게 재현되는 인스턴스-existential-루트 버그. PR 본문에
"관련 기존 버그"로 기록하고, 후속 소거 PR(또는 별도 이슈)에서 다룬다.

| 재현 | 6.3.3 릴리스 | main (asserts) |
|---|---|---|
| `protocol P { associatedtype A; var a: A { get } }`<br>`\(any P).a` | 컴파일러 크래시 (assert 4851) | 컴파일러 크래시 (assert 5029) |
| `protocol P { var shared: Self { get } }`<br>`\(any P).shared` | 컴파일러 크래시 (assert 4851) | 컴파일러 크래시 (assert 5029) |
| `protocol P { subscript(i: Int) -> Self { get } }`<br>`\(any P)[0]` | silgen 통과 (verifier 꺼짐, 잠복) | SIL verifier abort |
| `final class FB { let val = FB(); required init() {} }`<br>`protocol FQ: FB {}; \(any FQ).val` | 컴파일 OK → **런타임 크래시** (키패스 인스턴스화, libswiftCore) | IRGen `UNREACHABLE "not struct or class"` (GenKeyPath.cpp:760) |

마지막 행이 특히 고약하다: `Self`/associatedtype과 무관한 평범한 stored 클래스
멤버인데, same-module이라 stored-offset 컴포넌트로 내려가고 GenKeyPath가
existential 루트를 처리하지 못한다. 앞의 세 개는 후속 소거 PR이 자연히 고치고,
마지막 것은 stored-offset 컴포넌트의 루트 판정(`canStorageUseStoredKeyPathComponent`
또는 GenKeyPath) 수정이 따로 필요하다.

**업스트림 제보 현황 (2026-09-01 확인):**

- **A1 인스턴스 계열 — 제보됨.** canonical은
  [#69303](https://github.com/swiftlang/swift/issues/69303) (open, 2023 —
  `\(any P).value`, associatedtype, 같은 assert). 같은 계열 open:
  [#60214](https://github.com/swiftlang/swift/issues/60214) (`map(\.brand)`
  keypath-as-function 변형),
  [#63155](https://github.com/swiftlang/swift/issues/63155) (SILGenPoly
  "Unhandled transform?" 변형),
  [#76607](https://github.com/swiftlang/swift/issues/76607)
  (dynamicMemberLookup 크로스모듈 변형).
  [#84744](https://github.com/swiftlang/swift/issues/84744)는 2026-08-31에
  #69303의 dup으로 닫히며 main-snapshot-2026-08-30 재현이 확인됐다.
  `Self` 타입 변형(`var shared: Self`)은 별도 제보 없음 — #69303에 코멘트로
  추가할 만하다.
- **A3 인스턴스 (`\(any FQ).val` stored 멤버 런타임/IRGen 크래시) — 미제보.**
  가장 가까운 [#52227](https://github.com/swiftlang/swift/issues/52227)
  (SR-9807)은 서브클래스 루트 + 상속 let (existential 아님, resolved). 새 이슈
  제출 가치 있음.
- **A4 인스턴스 (`Self` 반환 첨자, verifier abort) — 미제보.** 릴리스 빌드에선
  verifier가 꺼져 있어 조용히 잠복하는 탓에 아무도 못 본 듯. 새 이슈 제출 가치
  있음 (asserts 빌드 재현 명시).
- **맥락: 이 패치가 지우는 진단의 출처.**
  [#87765](https://github.com/swiftlang/swift/issues/87765) (closed COMPLETED,
  2026-06)가 정확히 이 패치의 대상 형태(`KeyPath<P.Type, T>` + 정적 요구사항)의
  원본 크래시 제보이고,
  [swiftlang/swift#88474](https://github.com/swiftlang/swift/pull/88474)
  "Diagnose static key path members on protocol metatypes"가 크래시를 진단으로
  바꾸며 닫았다. **이 패치는 그 진단을 실제 지원으로 승격하는 것이므로 PR
  본문에서 #87765를 참조하고 #88474를 supersede 한다고 밝힐 것.** (#87765
  코멘트에는 "적용할 concrete 타입이 없으니 에러가 맞다"는 논의가 있는데,
  루트 *값*이 concrete 메타타입을 제공하므로 직접 접근 `type.foo`와 동일하게
  동작 가능하다는 반박이 이 패치의 논거다 — Constraints 테스트의
  `ordinaryLookup`이 그 근거.)

---

## 권장 작업 순서

**이 PR:**

1. **A1 좁힌 Sema 가드** (~10줄) — A1/A3/A4 메타타입 형태를 진단으로 복원.
   재현 입력들을 expected-error 테스트로 추가.
2. **A2** (AnyObject.Type Sema 진단) — 독립적이고 작다.
3. **B1** (게이트에 ProtocolDecl 예외) — 독립적이고 작다.
4. **D2 되돌리기, F 정리, E 테스트** — PR 다듬기.
5. PR 본문에 G절(기존 버그)과 C1–C3(feature-gated), D1(ABI 의존)을 기록.

**후속 PR:**

6. **SILGen 공변 소거** (A1의 후속 PR 절) — 가드 제거, `GlobalActor.shared`
   동작, G절의 인스턴스 크래시 세 개 함께 해결.
7. **G절 마지막 행** (stored-offset 컴포넌트 + existential 루트) — 별도 수정.
8. **C1–C3** — `KeyPathWithMethodMembers` 쪽 별도 PR.
