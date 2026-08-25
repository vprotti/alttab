<div align="center">

<img src="docs/icon.png" width="120" alt="AltTab">

# AltTab

**O ⌥ Tab que o Mac devia ter: uma janela por vez, com prévia.**

[nasmac.app](https://nasmac.app) · [English](README.en.md) · [Baixar](https://nasmac.app/downloads/AltTab.dmg)

<img src="docs/switcher.png" width="640" alt="Grade de janelas com prévia, ícone e título de cada uma">

</div>

---

Grátis, sem conta, sem anúncio, sem versão paga.

Segure ⌥ e aperte Tab. Aparece a grade com **todas as janelas abertas** — não uma pilha por app. Tab avança, ⇧Tab volta, solta o ⌥ e pronto. Igual ao Windows.

## Por que existe

O ⌘Tab do Mac alterna entre *aplicativos*. Se você tem dois Chromes abertos, um com o trabalho e outro com o perfil pessoal, ele mostra **um** Chrome. Chegar na janela certa vira ⌘Tab, depois ⌘` , depois adivinhar.

O AltTab mostra os dois, com o título de cada janela e uma prévia do que tem dentro.

## Como funciona

Cada linha é uma janela de verdade, na ordem em que estão empilhadas na tela — então um ⌥Tab sozinho volta para a janela de onde você acabou de sair.

- **Prévia de cada janela**, capturada na hora e sempre no mesmo tamanho.
- **Janelas minimizadas** entram na lista (dá para desligar), confirmadas com o app dono — a lista bruta do sistema mistura popups de extensão e janelas auxiliares que ninguém quer ver.
- **⇧Tab** volta, **setas** navegam, **Esc** cancela, **Enter** confirma, **clique** escolhe direto.
- **Atalho configurável**: ⌥ Tab de fábrica, mas pode ser ⌃ ou ⌘ com outra tecla.

## Instalar

Baixe o [DMG](https://nasmac.app/downloads/AltTab.dmg) — e **não abra ainda**.

O macOS bloqueia o arquivo baixado, porque o app ainda não é notarizado pela Apple: a notarização depende do programa pago de desenvolvedor. Antes de abrir, rode isto no Terminal:

```bash
xattr -dr com.apple.quarantine ~/Downloads/AltTab-1.0.0.dmg
```

Agora é só abrir o .dmg e arrastar o app para a pasta Aplicativos.

## As duas permissões

Na primeira abertura o AltTab pede duas coisas, e explica cada uma:

- **Acessibilidade** — obrigatória. É o que permite enxergar o ⌥ Tab e trazer a janela escolhida para a frente. Sem ela o app não faz nada.
- **Gravação de Tela** — opcional. Desenha as prévias e lê os títulos das janelas. Sem ela você vê o ícone e o nome do app, e tudo o mais continua funcionando.

### Liguei a permissão e ele continua dizendo que não

Isso tem uma explicação chata e é bom saber: **o macOS prende a permissão à cópia exata do app**, pelo hash do binário. Uma versão nova chega como se fosse outro programa, e a chave nos Ajustes continua ligada apontando para a cópia antiga.

Quando acontecer: em Ajustes do Sistema → Privacidade e Segurança → Acessibilidade, selecione o AltTab, aperte **−** para remover, e adicione de novo com **+**. O app avisa isso na tela quando detecta a situação.

Um certificado Developer ID da Apple resolve de vez, porque aí a permissão passa a valer para o app e não para o build. Está no plano.

## Compilar do código

Precisa só das Command Line Tools da Apple — não precisa do Xcode completo.

```bash
git clone https://github.com/vprotti/alttab.git
cd alttab
./scripts/build.sh
```

O resultado é `dist/AltTab.app`, universal (Apple Silicon e Intel). Para o instalador, `./scripts/dmg.sh`.

Útil ao mexer no código — imprime exatamente o que o alternador enxerga, com o estado das permissões:

```bash
./dist/AltTab.app/Contents/MacOS/AltTab --selftest-windows
```

## Como está montado

O atalho não podia ser um hot key do Carbon: ele avisa quando a tecla **desce**, e ⌥Tab é definido pelo modificador **subindo**. Então é um `CGEventTap` que observa `flagsChanged` e engole o Tab para ele não vazar para o app da frente.

A lista de janelas cruza duas fontes. O `CGWindowListCopyWindowInfo` dá a ordem de empilhamento e o id de cada janela, mas devolve mais de cem entradas — sombras, serviços de preenchimento, widgets. O filtro que separa uma janela de verdade é o dono ser um app com ícone no Dock. E a API de Acessibilidade é o único caminho público para de fato focar a janela, além de confirmar quais estão realmente minimizadas.

Ligar as duas exige traduzir um `CGWindowID` para um `AXUIElement`, o que a API pública não oferece. O `_AXUIElementGetWindow` faz isso e é resolvido em tempo de execução — se a Apple removê-lo um dia, o app cai para casar por título e posição, sem quebrar.

Prévias vêm do ScreenCaptureKit no macOS 14+ e da API antiga no 13, capturadas **depois** que a grade já apareceu, uma a uma — capturar tudo antes atrasaria a abertura, que é justamente o que faz um alternador parecer quebrado.

```
Sources/AltTab/WindowList.swift      quais janelas existem
Sources/AltTab/AXWindows.swift       a ponte com a Acessibilidade
Sources/AltTab/Hotkey.swift          segurar, ciclar, soltar
Sources/AltTab/SwitcherPanel.swift   a grade
Sources/AltTab/Thumbnails.swift      as prévias
```

Sem dependências externas.

## Privacidade

Tudo fica no seu Mac. Sem servidor, sem conta, sem telemetria. As prévias são desenhadas na tela e nunca saem do computador — não são gravadas em disco nem enviadas para lugar nenhum.

## Contribuir

Bug, ideia ou dúvida: [abra uma issue](https://github.com/vprotti/alttab/issues). Pull requests são bem-vindos — leia o [CONTRIBUTING](CONTRIBUTING.md) antes.

Se aparecer alguma janela que não devia estar na lista, ou faltar alguma que devia, a saída do `--selftest-windows` numa issue ajuda muito.

Se o AltTab te poupou tempo, uma ⭐ aqui no repositório ajuda outras pessoas a encontrarem o projeto. Leva um segundo e não custa nada.

Se quiser retribuir de outro jeito, aceito Bitcoin — mas o app continua grátis de qualquer forma:

```
bc1qs27wszjtkhku08nkmth4ctykyk9pa2nrfa2nlw
```

## Licença

[MIT](LICENSE). Use, modifique e redistribua à vontade, inclusive comercialmente.

Escrito do zero. Existe outro app de código aberto chamado AltTab, sob GPL, que não tem relação com este — nenhum código foi aproveitado de lá.

---

<div align="center">
Feito por <a href="https://viniciusprotti.com.br">Vinicius Protti</a> · <a href="https://nasralla.com.br">Nasralla Serviços Digitais</a><br>
Mais apps grátis para Mac em <a href="https://nasmac.app"><strong>nasmac.app</strong></a>
</div>
